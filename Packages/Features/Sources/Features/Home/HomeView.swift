import Core
import DesignSystem
import Flows
import ProfileKit
import RatingsKit
import SwiftUI

/// The Home screen: large hero area, rows below.
///
/// Layout follows the UI template. The hero area shows what played last,
/// because that is almost always what you want to watch next — one click instead of
/// searching first.
struct HomeView: View {

    @StateObject private var model: HomeModel
    @FocusState private var focus: String?
    @Environment(\.scenePhase) private var scenePhase
    /// The accent follows whatever is currently in focus. That way the
    /// series color moves with the gaze instead of sticking to one place.
    @State private var palette = AccentPalette.brand
    /// Which title is currently shown in the hero area.
    @State private var heroIndex = 0

    /// Whether the hero area was last paged forward **by hand**.
    ///
    /// The condition for a left press paging backward. Without it
    /// the backward catcher would be in the way even after automatic paging:
    /// Whoever wants to open the sidebar after twelve seconds of idling presses
    /// left — and would page instead. Whoever has just paged right themselves,
    /// on the other hand, means the way back by pressing left. If the focus leaves
    /// the hero area or the timer pages on, the permission lapses.
    /// When the hero area was last paged forward **by hand**.
    ///
    /// **A point in time and not a yes/no, and that is the correction of 2026-08-14
    /// in the evening.** Before, a switch stood here that the focus change flipped:
    /// When the focus left the hero area, the permission lapsed immediately. On the
    /// old remote, however, a long swipe left carries the focus into the sidebar
    /// first — the permission was gone **before** the gesture could even be
    /// evaluated. A left swipe therefore always came too late, and the hero area
    /// flew out of the frame instead.
    ///
    /// Measured against time, the intent is preserved even if the focus
    /// jumps in between. The deadline matches the dwell time of a title:
    /// Whoever wants to go back within it means the way back.
    @State private var forwardAt: Date?
    /// Keeps the move command and the swipe gesture apart — see ``MoveGate``.
    @State private var gate = MoveGate()

    /// How long a title stays at the top.
    ///
    /// Twelve seconds, not five: The text should be readable, and every
    /// switch fetches a new background image over the network. On a narrow
    /// connection quick paging would be a flood of images that never finishes loading.
    private static let heroInterval = HomeLayout.heroRotation

    /// The area of the hero.
    ///
    /// Full screen width and 860 of 1080 points of height. As a value and not as a number in
    /// the frame, because the same size is needed in two places: for the layout and
    /// for the size to which the background image is decoded downscaled. Two
    /// numbers would drift apart at the first change, and one of them would have
    /// stayed invisibly wrong.
    static let heroSize = CGSize(width: 1920, height: 860)

    /// How far to zoom into the background image.
    ///
    /// **The anchor alone was at its limit.** Anchored at the top, the top edge of the image lies
    /// on the top edge of the screen — the motif cannot go lower that way, no matter how tall
    /// the area is. A 16:9 background is stretched to 1920 points of width and is
    /// thus 1080 tall; its center sits firmly at 540, and the height of the area
    /// only determines where it is cut off at the bottom.
    ///
    /// The only way down without an empty strip at the top is therefore to zoom into the
    /// image: At a factor of 1.12 the image is 1210 points tall, its center sits
    /// at 605 — the motif sinks by 65 points, a good four centimeters on a 55-inch set.
    ///
    /// The price is paid with the sides: 115 points are lost left and right. On the left
    /// the opaque gradient for the text lies there anyway, on the right it is incidental in a
    /// background image. **Whoever wants to go further turns this one number** — and
    /// must then check the side loss, see `HomeLayoutTests`.
    static let heroZoom: CGFloat = 1.12

    /// The corner radius of the hero area. The same as on the tiles.
    static let heroCornerRadius: CGFloat = 28

    /// How far the content is inset from the card edge — since the outline
    /// makes the edge visible; derivation at the caller of ``heroText(_:)``.
    static let heroContentInset: CGFloat = 48

    let onSelect: (MediaItem) -> Void

    /// Continues playing a title from "Continue Watching" at its position — see
    /// ``HomeModel/playsOnPress(_:inShelf:)``.
    let onContinue: (MediaItem) -> Void

    /// "Details" from the long press — **the series page**, not the episode's, even where
    /// the source first has to look up the series (``Core/ContentSource/seriesReference(zu:)``).
    let onDetails: (MediaItem) -> Void

    /// Reports to the shell whether the page is scrolled — the pill then steps aside.
    ///
    /// **Without a default value:** A caller that forgets the report would get
    /// a pill that the card edge slides under while scrolling — exactly
    /// the finding this report exists for.
    let onScrollChanged: (Bool) -> Void

    /// Where a state button leads that this view cannot handle itself.
    let onAction: (ActionTarget) -> Void

    /// "All" at the end of a library shelf — the tab of its kind, opened on this library (AP89).
    let onOpenLibrary: (Core.Library) -> Void

    init(
        model: HomeModel,
        onScrollChanged: @escaping (Bool) -> Void,
        onAction: @escaping (ActionTarget) -> Void,
        onContinue: @escaping (MediaItem) -> Void,
        onDetails: @escaping (MediaItem) -> Void,
        onOpenLibrary: @escaping (Core.Library) -> Void = { _ in },
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onOpenLibrary = onOpenLibrary
        self.onScrollChanged = onScrollChanged
        self.onAction = onAction
        self.onContinue = onContinue
        self.onDetails = onDetails
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            switch model.state {
            case .loading:
                // **A state and not a home-grown screen** (AP25, 2026-09-11). Three
                // self-built screens stood here — loading, failure, empty —, each with its
                // own symbol, its own sentence and its own focus rule. ``PlaybackPhase``
                // was built for this and had **zero** callers in the whole production code;
                // the only occurrence was the demo in the diagnostics.
                //
                // **The focus rule comes along and is not repeated here:** A
                // task takes the focus, a piece of information does not — that is in the header of
                // ``StateView`` and thus applies equally everywhere. The
                // `focusAnchor` that stood here for the empty case is dropped without replacement.
                StateView(state: .loadingStart)
                    .focusAnchor("home-loading", focus: $focus)
            case .failed(let state):
                // A task brings its button along and takes the focus itself —
                // ``StateView`` rule 1. No anchor is needed here.
                StateView(state: state, onAction: handle)
            case .empty:
                // **The anchor stays, and exactly here** (AP25). A piece of information has
                // nothing to press and therefore expressly takes no focus; without
                // an anchor tvOS would take the nearest target, and in this
                // app that is the sidebar — it would unfold and push the content aside by 232
                // points. See ``FocusAnchor``.
                StateView(state: .emptyLibrary)
                    .focusAnchor("home-empty", focus: $focus)
            case .ready(let heroes, let shelves):
                content(heroes: heroes, shelves: shelves)
            }
        }
        .environment(\.accentPalette, palette)
        .task { await model.load() }
        // **Fresh on coming back** (2026-09-28): The Home screen loaded only on the first
        // appearance; what played on the phone was missing until a restart.
        .onChange(of: scenePhase) { _, fresh in
            if fresh == .active { Task { await model.fresh() } }
        }
        // **And when something arrives from the cloud** (2026-09-28): Progress, shelf order
        // and channel history from the phone land in the ledger, but the Home screen showed them only
        // on the next return. It is reported only when something has changed.
        .onReceive(NotificationCenter.default.publisher(for: ProfileCloud.arrived)) { _ in
            Task { await model.load(force: true) }
        }
        // Try again after a failure as soon as the TV comes back —
        // see ``RetriesWhenAwake``. Without it "No response" stayed up until one
        // signed out and in again.
        .retriesWhenAwake(isFailed: model.state.isFailed) { await model.load(force: true) }
    }

    // MARK: - Content

    private func content(heroes: [MediaItem], shelves: [HomeModel.Shelf]) -> some View {
        // The area is taken completely, so that no other background shows through
        // under the last row.
        //
        // The top safe-area inset is lifted here and not at the image:
        // The scrolling area otherwise already subtracts it, and the image began
        // only below the bar — it looked pasted in instead of filling the screen.
        ScrollView {
            // **`LazyVStack` and not `VStack`.** An ordinary stack builds all
            // rows immediately, including the four below the image — with every
            // tile in them and with their image fetches. With five shelves that is around
            // fifty posters at once: more than the cache holds, so it
            // evicts while still loading. That was the main cause of the
            // Home screen stuttering on the TV and images failing to appear.
            LazyVStack(alignment: .leading, spacing: MetricsBoard.tv.section) {
                if !heroes.isEmpty {
                    // The index is clamped, because a reload can deliver fewer
                    // titles than last time.
                    let current = heroes[min(heroIndex, heroes.count - 1)]

                    heroSection(current)
                        // **`.id(current.id)` stood here, and it was the cause of the
                        // flicker every twelve seconds.**
                        //
                        // An identity of its own means to SwiftUI: a different view. The
                        // whole subtree was discarded when paging on, including the
                        // `RemoteImage` and its state. The new one started from zero,
                        // showed the gray placeholder and loaded 200 KB afresh — visible
                        // as a gray field that flashes up, reliably on every
                        // switch.
                        //
                        // Without the identifier it stays the same view. ``RemoteImage``
                        // holds its old image until the new one is decoded — exactly
                        // what it is built for —, and the switch is a cross-fade instead of
                        // a hole.
                        .overlay(alignment: .bottomTrailing) {
                            if heroes.count > 1 {
                                heroPager(count: heroes.count)
                                    .padding(.trailing, MetricsBoard.tv.margin)
                                    .padding(.bottom, 52)
                                    // The dots only say where one
                                    // stands — they cannot be selected. An overlay
                                    // does take part in determining the focus target, though, and
                                    // here it lies over the hero area, where the
                                    // play button sits.
                                    .allowsHitTesting(false)
                            }
                        }
                        // Only paging to the right goes this way. Left is deliberately
                        // free here: That is where the sidebar unfolds, and a left command
                        // intercepted here would never get there — the menu
                        // could no longer be opened from the hero area.
                        // Backward still works, but via a focus target instead of
                        // this command, see ``pageBackCatcher``.
                        .onMoveCommand { direction in
                            heroStep(direction, count: heroes.count, from: .command)
                        }
                        // **The second way, for the old remote.** On the
                        // smooth glass surface, swiping produces no
                        // move command — see ``RemoteSwipeDirection``. Without
                        // this addition the hero area stood still there, and because
                        // ``didPageForward`` never became true, the way back
                        // via ``pageBackCatcher`` was missing along with it: A single
                        // missing command shut down both directions
                        // (finding of 2026-08-14).
                        .onRemoteSwipe("Start") { swipe in
                            heroStep(swipe.asMove, count: heroes.count, from: .gesture)
                        }
                        .padding(.bottom, 20)
                }

                ForEach(shelves) { shelf in
                    shelfSection(shelf)
                }
            }
            .padding(.bottom, TVMetrics.topMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Is the page scrolled? It is reported only from forty points on, not
        // from the first: Small corrective jerks of the focus scrolling should not
        // make the pill flicker. The frame then fades it out — the
        // card with its outline otherwise visibly slid under the floating
        // capsule (viewer screenshot 2026-08-07, 21:57).
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > 40
        } action: { _, isScrolled in
            onScrollChanged(isScrolled)
        }
        // The focus starts on the play button. Without this, tvOS looks
        // for the first focusable element — and that was the sidebar,
        // which thereby stood unfolded when the app opened and covered a quarter
        // of the image.
        .defaultFocus($focus, "hero-play")
        .background(ColorRole.reason.color)
        // Top, bottom and right — **not left**. tvOS keeps 80 points free at the sides
        // for the overscan area of old TVs; since every piece of content here
        // brings its own inset, that would be doubled, and on the right
        // a strip of base color remained next to the background image.
        //
        // On the left the inset must stay, though: That is where the sidebar stands. Without
        // this restriction the scrolling area stretched under it and
        // cut off the first characters of every heading — "Series" lost
        // its S, "Skeblus deitseflaum Poblaplal" its A.
        //
        // **At the top, breaking out is MANDATORY, not legacy** (dead end of 2026-08-07,
        // removed for an evening): The pill in the frame measures its position from the
        // absolute screen edge — whoever keeps the safe-area inset here gets
        // ~60 points on top from the navigation frame and measures
        // ``MediaTabBar/reservedTop`` from a lower origin: The card
        // hung 80 instead of 20 points below the pill. Only with the same origin
        // does the computation work. That the card slid under the pill while
        // SCROLLING is not a coordinate error and is solved in the frame: The
        // pill steps aside via opacity while scrolled.
        .ignoresSafeArea(edges: [.top, .bottom, .trailing])
        // The third-party rating for the shown title — at the same persistent
        // place as the timer and for the same reason. At the hero area itself
        // the fetch was cleared away on switching, and the rating never
        // appeared. Fetching all candidates up front would be eight requests for seven
        // numbers nobody reads.
        .task(id: heroIndex) {
            guard !heroes.isEmpty else { return }
            await model.loadHeroRatings(for: heroes[min(heroIndex, heroes.count - 1)])
        }
        // **Fetch the next background image beforehand.**
        //
        // Without that, every switch started with an empty cache: The image
        // was requested only when it was needed, and until it arrived the
        // placeholder stood. Twelve seconds is plenty of time to fetch it beforehand — and
        // it is fetched at **the same** size the view later asks for, otherwise
        // it lies under a different key and the hit misses.
        // **The accent color is fetched afterwards, when the focus is settled — not at every
        // step.** Before, every tile had an observation of its own with an
        // unstructured `Task`; it was not cancelled at the next step.
        // Whoever held the direction key produced a queue of color fetches for
        // titles they were only moving past — and these took the connections away
        // from the visible posters. See ``FocusFollowUp``.
        .whenFocusSettles(on: focus) { current in
            guard let item = Self.item(for: current, in: shelves) else { return }
            palette =
                await AccentExtractor.shared
                .palette(for: model.accentSourceURL(for: item)) ?? .brand
        }
        .task(id: heroIndex) {
            guard heroes.count > 1 else { return }
            let next = (heroIndex + 1) % heroes.count
            guard let url = model.backdropURL(for: heroes[next]) else { return }
            _ = await ImageCache.shared.image(
                for: url,
                decodeLimit: ImageSizing.decodeLimit(points: Self.heroSize, headroom: Self.heroZoom)
            )
        }
        // The timer for the hero area hangs here and not on the hero area
        // itself: That is swapped for the next title on every switch,
        // and a timer attached to it dies with it — the switch then happened
        // exactly once. Up here the place persists.
        .task {
            while !Task.isCancelled {
                let before = heroIndex
                try? await Task.sleep(for: Self.heroInterval)
                guard !Task.isCancelled, heroes.count > 1 else { continue }
                // Whoever has paged by hand in the meantime wants to read:
                // This tick lapses, the time starts over.
                guard heroIndex == before else { continue }
                advanceHero(by: 1, count: heroes.count)
                // Nobody steered the automatic paging — a left press
                // afterwards means the sidebar again, not the way back.
                forwardAt = nil
            }
        }
        // The resolution of the backward catcher: If the focus lands on it, that was
        // a left press from the play button — one step back, and the focus
        // returns there immediately. If it leaves the hero area in another
        // direction, the paging permission lapses, see ``didPageForward``.
        .onChange(of: focus) { _, current in
            if current == "hero-back" {
                // The check is there twice for safety: The catcher does not exist
                // at the first entry at all — there is no paging backward in a circle, left of the start
                // lies the sidebar. That the step does not pull the catcher out from under the focus is
                // ensured by the condition on its overlay.
                //
                // **Through the same gate as the gesture**, otherwise a
                // left press pages two steps: once via this catcher and once
                // via ``heroStep(_:count:from:)``. As a gesture, because the catcher is
                // the same second observer: It triggers because the
                // movement shifted the focus — on the click ring the
                // command carries the input, and the catcher is its echo.
                if heroIndex > 0, gate.accepts(.left, .now, from: .gesture) {
                    advanceHero(by: -1, count: heroes.count)
                }
                focus = "hero-play"
            }
        }
    }

    /// Pages on in the hero area and wraps around.
    private func advanceHero(by offset: Int, count: Int) {
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            heroIndex = (heroIndex + offset + count) % count
        }
    }

    /// Whether a left press on the play button pages backward.
    ///
    /// Only if there is something backward **and** the last paging movement
    /// came by hand. Both are consideration for the sidebar: At the first
    /// entry left still leads where it always led — into the menu.
    /// And likewise after automatic paging, because nobody wants to undo a
    /// movement they did not make.
    static func allowsPageBack(
        index: Int,
        forwardAt: Date?,
        now: Date,
        deadline: TimeInterval = 12
    ) -> Bool {
        guard index > 0, let forwardAt else { return false }
        return now.timeIntervalSince(forwardAt) < deadline
    }

    /// One step forward in the hero area — from both sources, counted once.
    ///
    /// **Only to the right, and that stays so.** Left is deliberately free here: That is where
    /// the sidebar unfolds, and a left command intercepted here would
    /// never get there. Backward goes via ``pageBackCatcher`` — a focus target
    /// that the old remote also reaches, because swiping does move the focus;
    /// it just produces no move command.
    private func heroStep(
        _ direction: MoveCommandDirection, count: Int, from source: MoveSource
    ) {
        // **To the left only if backward can be meant at all** — otherwise
        // left still leads where it always led: into the menu. The
        // focus may already be there at this point; a long swipe
        // carries it over on the old remote before the gesture ends.
        // That is why it is explicitly fetched back — an assignment, and that
        // knows no area boundary.
        if direction == .left {
            guard Self.allowsPageBack(index: heroIndex, forwardAt: forwardAt, now: .now),
                gate.accepts(direction, .now, from: source)
            else { return }
            advanceHero(by: -1, count: count)
            focus = "hero-play"
            return
        }
        guard direction == .right, gate.accepts(direction, .now, from: source) else { return }
        advanceHero(by: 1, count: count)
        // Only now, not at the timer tick: Only whoever has paged forward themselves
        // gets left as the way back.
        forwardAt = .now
    }

    /// The invisible focus target to the left of the play button.
    ///
    /// **Why no `onMoveCommand`:** The move command arrives there only if
    /// the focus finds no target in that direction — left of the button, however, lies
    /// the sidebar, so the focus moves before the command fires. An
    /// intercepted left command in turn would take every way away from the menu. Hence a
    /// narrow target of its own in between: The left press lands here, pages
    /// one title back, and the focus returns to the button immediately — the
    /// resolution hangs on the focus change, see `onChange` in ``content``. The same
    /// pattern as the `pauseCatcher` of playback: a button nobody sees
    /// and that only carries the focus. Since it exists only while the focus rests on the
    /// play button (``didPageForward`` lapses on leaving), no
    /// other direction can hit it by accident either.
    private var pageBackCatcher: some View {
        Button {
        } label: {
            Color.clear
                .frame(width: 8, height: 64)
        }
        .bareFocusableButton()
        .focused($focus, equals: "hero-back")
        .accessibilityHidden(true)
    }

    /// Shows how many titles are running at the top and where one stands.
    ///
    /// Without this indicator the switch looks like the app having a life of its own. With it
    /// it is recognizable that this is a series of titles one can also page
    /// through oneself.
    private func heroPager(count: Int) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(
                        index == heroIndex
                            ? ColorRole.text.color
                            : ColorRole.text.color.opacity(0.28)
                    )
                    // The active dot gets wider instead of just brighter — at three
                    // meters' distance shape is easier to recognize than brightness.
                    .frame(width: index == heroIndex ? 34 : 11, height: 11)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: heroIndex)
    }

    // MARK: - Hero area

    private func heroSection(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            // The background image reaches to the edges; the gradients expose
            // the text and tie in the transition to the first row. Without the
            // bottom gradient the row floats in the image.
            // Reaches to the top edge, the bar lies above it — that is how
            // the big providers do it. Before, the image began only
            // below the bar and looked pasted in.
            // Width **and** height must be given. With only the height,
            // the aspect ratio of the image determines the width — for a
            // 2.13:1 background that was 1833 instead of 1920 points, and on the right
            // a strip of base color remained. The error depended on the
            // particular image and was therefore not always visible.
            //
            // **The crop hangs at the top, not in the middle.** A background image comes
            // in 16:9 format, the area is 2.23:1 — 220 points are left over. Distributed
            // centrally, 110 of them were lost at the top, and on the TV exactly that was
            // visible: The head of the motif was clipped, the image sat too high.
            //
            // Anchored at the top, the top edge of the image stays complete, and the excess
            // is lost at the bottom — where the opaque gradient for the text lies anyway.
            // The motif thereby moves down in the image.
            //
            // **For a while `.bottom` stood here, and that was the wrong
            // direction:** Anchored at the bottom, *more* is cut off at the top, not less.
            // Whoever sets the anchor must realize that the anchored edge is the
            // *remaining* one — the cut happens opposite.
            RemoteImage(
                url: model.backdropURL(for: item),
                // The anchor belongs **here** and not on the frame below: The
                // image grows beyond the frame, and where it sits while doing so is decided by
                // the alignment inside ``RemoteImage``. An `alignment` on the
                // `.frame` only aligns the image view as a whole — which is
                // exactly as large as the frame, so it does nothing.
                alignment: .top,
                displaySize: Self.heroSize,
                // The hero area does not grow on focus.
                headroom: 1,
                // Anchored at the top **and** zoomed in: only together does the motif come
                // as low as it should sit on the TV. See ``heroZoom``.
                zoom: Self.heroZoom
            )
            .frame(maxWidth: .infinity, minHeight: Self.heroSize.height, maxHeight: Self.heroSize.height)
            // **Rounded and not edge-to-edge.** Edge-to-edge was the template of the big
            // providers; on our own device the rounded area looks calmer, because it
            // stands out from the black ground as a card instead of fading into it.
            // The radius is the same as on the tiles — two different roundings
            // on one screen read as indecision.
            .clipShape(RoundedRectangle(cornerRadius: Self.heroCornerRadius, style: .continuous))
            .padding(.horizontal, MetricsBoard.tv.margin)
            // **The image begins below the pill, not behind it.**
            //
            // Here it ran up to the top screen edge, on the grounds that the big providers did it
            // that way and anything else looked "pasted in". On the TV
            // that is not true: Pill and image then lie at the same height and read
            // as one element. First opaque, then set lower — the viewer
            // reported it three times, and they see it, I do not.
            //
            // The distance comes from ``MediaTabBar/reservedTop`` and is thus tied to the
            // height of the pill, not guessed.
            .padding(.top, MediaTabBar.reservedTop)
            .overlay {
                LinearGradient(
                    colors: [
                        ColorRole.reason.color,
                        ColorRole.reason.color.opacity(0.85),
                        ColorRole.reason.color.opacity(0.15),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay {
                // With explicit stops instead of evenly distributed
                // colors — and the bottom eight percent **fully
                // opaque**.
                //
                // Before, the gradient faded out evenly and reached only about seventy percent
                // opacity at the bottom edge. Measured:
                // brightness 33 just above the edge, 11 below. This
                // jump was visible as a hard line — barely with dark images,
                // immediately with a bright one.
                LinearGradient(
                    stops: [
                        .init(color: ColorRole.reason.color, location: 0),
                        .init(color: ColorRole.reason.color, location: 0.08),
                        .init(color: ColorRole.reason.color.opacity(0.72), location: 0.24),
                        .init(color: ColorRole.reason.color.opacity(0.22), location: 0.5),
                        .init(color: .clear, location: 0.72),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
            .overlay {
                // **The colored outline when the focus rests in the hero area.**
                // The Watch button alone is easy to overlook on a bright, full-screen
                // image — the edge in the accent color makes it unmistakable at three
                // meters' distance that the focus is at the top. Tiles
                // deliberately do without frames (see ``FocusHighlight``); the
                // hero area is the exception, because it does not grow and a
                // jump in size at 1856 points of width would shift everything.
                //
                // Drawn after the gradients, not before: On the left the
                // text gradient runs at full opacity up to the card edge and
                // would otherwise swallow the line. Via opacity instead of a
                // conditional modifier — the chain stays the same, only the value
                // changes, as everywhere with focus.
                RoundedRectangle(cornerRadius: Self.heroCornerRadius, style: .continuous)
                    .stroke(Color(palette, .bright), lineWidth: 5)
                    .padding(.horizontal, MetricsBoard.tv.margin)
                    .padding(.top, MediaTabBar.reservedTop)
                    .opacity(focus == "hero-play" || focus == "hero-back" ? 1 : 0)
                    .animation(Tokens.Focus.animation, value: focus == "hero-play" || focus == "hero-back")
                    .allowsHitTesting(false)
            }

            heroText(item)
                // **With padding to the card, not flush with its edge.**
                // The text began at `safeX` — exactly where the card
                // begins. Without a frame this never showed; with the outline the
                // title lettering and the Watch button lay on the line and protruded into it with
                // the focus enlargement (viewer screenshot 2026-08-07). The
                // bottom padding grows along so that the button with its glow stands free
                // in front of the line.
                .padding(.horizontal, MetricsBoard.tv.margin + Self.heroContentInset)
                .padding(.bottom, 56)
                // Enough space at the top so that the text does not slide under the bar
                // while the image continues behind it.
                //
                // **Only the text keeps its distance, not the image** — that is the
                // difference from the library, where all the content moves under the pill.
                // A hand-picked 120 stood here; the computation yields practically
                // the same value but is tied to the height of the pill.
                .padding(.top, MediaTabBar.reservedTop)
                // **The catcher for the press down from the pill.** Directly
                // below the center of the pill there is no focusable target — the
                // play button sits far left, outside the search cone, and
                // the press fizzled (proven with probes, 2026-08-07). As a
                // section the whole text column counts; it lies clearly
                // below the pill and overlaps it horizontally — the press
                // hits it, and inside, the play button wins.
                .focusSection()
        }
    }

    private func heroText(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Where a logo lettering is on file, it looks more high-quality than
            // set text — the big providers make the same choice.
            if let logo = model.logoURL(for: item) {
                RemoteImage(
                    url: logo,
                    contentMode: .fit,
                    displaySize: TVMetrics.logo,
                    headroom: 1
                )
                .frame(
                    maxWidth: TVMetrics.logo.width,
                    maxHeight: TVMetrics.logo.height,
                    alignment: .leading
                )
                .padding(.bottom, 22)
            } else {
                Text(item.parentTitle ?? item.title)
                    .font(TypeLevel.lead.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)
                    .padding(.bottom, 18)
            }

            if let progress = item.progress, progress.isResumable {
                resumeLabel(item)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(palette, .bright))
                    .padding(.bottom, 12)
            }

            if model.surface.showsExtras {
                heroAccessories(item)
            } else {
                Color.clear.frame(height: 12)
            }

            HStack(spacing: 22) {
                // **The button now only promises what it delivers.** It carried a
                // play symbol and "Play"/"Continue Watching", but led to the
                // detail page — the first press of the whole app thereby broke its
                // promise. Actually playing would mean passing the bridge from
                // `MainView.startPlayback` down to here and resolving series to their
                // next episode; playback deliberately has a single
                // owner in the frame ("The player lies above everything and in ONE
                // place"), and the Home screen gets only `onSelect` from it.
                // Until the frame passes down a play path, the honest
                // label is the right half: "Watch" without a play symbol.
                // On the detail page the resume button is already in focus —
                // two presses remain until the picture, just without a broken expectation.
                Button {
                    onSelect(item)
                } label: {
                    Text(app: "home.view")
                        .font(TypeLevel.header.font)
                        .foregroundStyle(
                            focus == "hero-play" ? ColorRole.text.color : ColorRole.reason.color
                        )
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                        .background(
                            focus == "hero-play" ? Color(palette) : ColorRole.text.color,
                            in: Capsule()
                        )
                }
                .bareFocusableButton()
                .focused($focus, equals: "hero-play")
                .focusHighlight(
                    focus == "hero-play",
                    scale: Tokens.Focus.buttonScale,
                    accent: Color(palette, .bright)
                )
                .overlay(alignment: .leading) {
                    // See ``pageBackCatcher`` — only in the view as long as there is
                    // anything to fetch backward. **And as long as it carries
                    // the focus:** On the step from entry one to zero it would otherwise drop
                    // out of the hierarchy in the same pass in which the focus still lies on
                    // it — tvOS then reassigns it itself. In the simulator
                    // it wandered onto the pill, whose area follows the focus;
                    // the Home screen was torn down and the focus ended up stranded in the
                    // sidebar. One left press, three unwanted switches.
                    if Self.allowsPageBack(index: heroIndex, forwardAt: forwardAt, now: .now)
                        || focus == "hero-back"
                    {
                        pageBackCatcher
                            .offset(x: -34)
                    }
                }
            }
        }
    }

    /// Meta line, ratings and synopsis of the hero image — **as one unit**, because
    /// the child UI leaves them out as one (``Surface/showsExtras``).
    @ViewBuilder
    private func heroAccessories(_ item: MediaItem) -> some View {
        metaRow(item)
            .padding(.bottom, 14)

        let external = model.heroRatings[item.id] ?? ExternalRatings()
        if RatingBadges.hasContent(serverRatings: item.ratings, external: external) {
            RatingBadges(serverRatings: item.ratings, external: external)
                .padding(.bottom, 18)
        }

        if let overview = item.overview, !overview.isEmpty {
            Text(overview)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .lineLimit(2)
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.bottom, 28)
        }
    }

    /// Here too `Text` instead of a string — see ``EpisodeCard``.
    @ViewBuilder
    private func resumeLabel(_ item: MediaItem) -> some View {
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            Text(app: "home.resumeAt \(season) \(episode)")
        } else {
            Text(app: "home.continueWatching")
        }
    }

    private func metaRow(_ item: MediaItem) -> some View {
        HStack(spacing: 18) {
            if let year = item.year {
                Text(verbatim: String(year))
            }
            if let age = item.ageRating {
                dot
                Text(verbatim: age)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(ColorRole.textQuiet.color, lineWidth: 2)
                            // The outline is ornament and stays pass-through. Today
                            // only text lies below it; but experience shows the row
                            // migrates into cards and buttons, and there it would be
                            // the next focus nobody can find any more.
                            .allowsHitTesting(false)
                    }
            }
            if !item.genres.isEmpty {
                dot
                Text(item.genres.prefix(2).joined(separator: " · "))
            }
        }
        .font(TypeLevel.footer.font)
        .foregroundStyle(ColorRole.textMatt.color)
    }

    private var dot: some View {
        Circle()
            .fill(ColorRole.textQuiet.color)
            .frame(width: 6, height: 6)
    }

    // MARK: - Rows

    private func shelfSection(_ shelf: HomeModel.Shelf) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(appKey: shelf.titleKey)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, MetricsBoard.tv.margin)

            ScrollView(.horizontal) {
                // Lazy here too: A shelf holds up to twenty titles, six are visible.
                // The remaining fourteen would fetch their poster before they even
                // come into view.
                LazyHStack(alignment: .top, spacing: MetricsBoard.tv.gutter) {
                    ForEach(shelf.items) { item in
                        card(item, shelf: shelf)
                    }
                    if let library = Self.allTarget(for: shelf, in: model.libraries) {
                        allCard(library, shelf: shelf)
                    }
                }
                .padding(.horizontal, MetricsBoard.tv.margin)
                // So that enlarged tiles are not clipped at the edge.
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }

    private func card(_ item: MediaItem, shelf: HomeModel.Shelf) -> some View {
        let id = "\(shelf.id)-\(item.id)"

        return Button {
            if HomeModel.playsOnPress(item, inShelf: shelf.id) {
                onContinue(item)
            } else {
                onSelect(item)
            }
        } label: {
            if shelf.usesWideCards {
                let image = model.tileImage(for: item)
                EpisodeCard(
                    item: item,
                    imageURL: image?.url,
                    isPortraitImage: image?.up ?? false,
                    isFocused: focus == id
                )
            } else {
                PosterCard(
                    item: item,
                    imageURL: model.posterURL(
                        for: item,
                        width: ImageSizing.requestWidth(
                            points: model.surface.posterSize.width)),
                    isFocused: focus == id,
                    size: model.surface.posterSize
                )
            }
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .contextMenu { cardMenu(for: item, shelf: shelf) }
    }

    /// The library behind a shelf's "All" card — `nil` if the shelf gets none (AP89).
    ///
    /// **Only with two or more libraries of the kind**, the same threshold as the title choice in
    /// the tab: with a single one the tab shows it anyway, and Home stays exactly as it was.
    /// Only library shelves qualify — "Recently Added" or a portal folder has no tab to open.
    nonisolated static func allTarget(
        for shelf: HomeModel.Shelf, in libraries: [Core.Library]
    ) -> Core.Library? {
        guard let library = libraries.first(where: { $0.id == shelf.id }),
            MediaTabBar.Section(libraryKind: library.kind) != nil,
            LibraryChoice.offersChoice(libraries, kind: library.kind)
        else { return nil }
        return library
    }

    static func allCardID(_ shelf: HomeModel.Shelf) -> String { "\(shelf.id)-all" }

    /// The card at the end of the shelf that opens the full library — the size of its
    /// neighbors, so the row ends in a card and not in a gap.
    private func allCard(_ library: Core.Library, shelf: HomeModel.Shelf) -> some View {
        let id = Self.allCardID(shelf)
        let isFocused = focus == id
        let size =
            shelf.usesWideCards
            ? CGSize(width: MetricsBoard.tv.episode.width, height: MetricsBoard.tv.episode.height)
            : model.surface.posterSize

        return Button {
            onOpenLibrary(library)
        } label: {
            VStack(spacing: 12) {
                Text(app: "common.all")
                    .font(TypeLevel.header.font)
                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.header.font)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.textMatt.color)
            .frame(width: size.width, height: size.height)
            .background(
                isFocused ? ColorRole.text.color : ColorRole.surface.color,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ColorRole.line.color, lineWidth: isFocused ? 0 : 2)
                    .allowsHitTesting(false)
            }
            .focusHighlight(isFocused)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .accessibilityLabel(Text(app: "home.allInLibrary \(library.name)"))
    }

    /// The long-press menu of a Home screen card — the same two actions as
    /// in the library, with the same keys: An action that carries two names
    /// in two places reads as two actions.
    ///
    /// In "Continue Watching" "Reset progress" is added — the only
    /// way to get an accidentally started title out of the row again
    /// without marking it as watched.
    ///
    /// **Which actions apply is decided by ``HomeModel/cardActions(forItem:inShelf:)``** — a
    /// channel tile gets only "Remove from Continue Watching" (Live check, finding 7).
    @ViewBuilder
    private func cardMenu(for item: MediaItem, shelf: HomeModel.Shelf) -> some View {
        ForEach(HomeModel.cardActions(forItem: item, inShelf: shelf.id), id: \.self) { action in
            switch action {
            case .details:
                Button {
                    onDetails(item)
                } label: {
                    Label(app: "common.details", systemImage: "info.circle")
                }
            case .seen:
                Button {
                    Task { await model.toggleWatched(for: item) }
                } label: {
                    Label(
                        app: item.isWatched ? "detail.markUnwatched" : "common.markWatched",
                        systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
            case .favorite:
                Button {
                    Task { await model.toggleFavorite(for: item) }
                } label: {
                    Label(
                        app: item.isFavorite ? "common.unfavorite" : "detail.favorite",
                        systemImage: Glyph.favorite.pair.forItem(item.isFavorite)
                    )
                }
            case .fromContinueWatching:
                Button {
                    Task { await model.removeFromContinueWatching(item) }
                } label: {
                    Label(app: "home.removeFromResume", systemImage: Glyph.remove.name)
                }
            }
        }
    }

    /// The title the focus is on — looked up via the identifier.
    ///
    /// The identifier is `<shelf>-<title>`, because the same title can appear in two shelves
    /// and the focus could not tell them apart otherwise.
    static func item(for focus: String?, in shelves: [HomeModel.Shelf]) -> MediaItem? {
        guard let focus else { return nil }
        for shelf in shelves {
            if let match = shelf.items.first(where: { "\(shelf.id)-\($0.id)" == focus }) {
                return match
            }
        }
        return nil
    }

    // MARK: - What the state triggers

    /// What the button of a state does.
    ///
    /// **`.retry` keeps the view, everything else passes it on.** "Load again"
    /// here means "this Home screen once more" and nowhere else the same; the ways
    /// out of the view — accounts, settings, sync — lie in the
    /// shell, and that is where they go.
    private func handle(_ target: ActionTarget) {
        if case .retry = target {
            Task { await model.load(force: true) }
        } else {
            onAction(target)
        }
    }
}
