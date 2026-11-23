import Core
import DesignSystem
import Playback
import SwiftUI

/// A person's career, laid over whatever you are currently watching.
///
/// **Over the page and not as a page of its own** — and this difference carries
/// the whole design: it is opened from two contexts, from the detail page
/// and **while a film is playing**. A page of its own would mean, in the second
/// case, leaving playback; nobody wants that who only wanted to know where
/// they know the face from. That is why it lies above, does not take the whole
/// screen, and the Menu button brings you back.
///
/// **Two tabs instead of one list**, because an actor with forty films
/// and sixty series appearances would otherwise yield a list in which nothing can
/// be found. Within a tab from new to old: whoever looks someone up almost
/// always wants the most recent — "what are they doing now".
struct FilmographySheet: View {

    @StateObject private var model: FilmographyModel
    let onOpen: (String) -> Void
    let onClose: () -> Void
    /// Plays the trailer of a foreign title from the short profile (AP78) — in the shell's player.
    let onPlay: (PlaybackTarget) -> Void

    @State private var tab: Tab = .movies
    @FocusState private var focus: String?

    /// When the operator last did something themselves — the follow-up then
    /// gives up (AP4 · K7, ``FocusRules/abandonsRetry(startedAt:lastInput:grace:)``).
    @State private var lastInputAt = Date.distantPast
    @Environment(\.accentPalette) private var palette

    /// Counts up when the Menu button was caught **outside** and the
    /// window should still do what it means.
    ///
    /// **In the player's full-screen cover it does not arrive in here**, and
    /// this is verified in the simulator (2026-08-12): the focus demonstrably stood on
    /// a row of this window, and the press still closed the whole
    /// film. The same lesson has stood since 2026-08-07 at ``PlayerScreen/panels``:
    /// there **every** panel catches the key itself, because it never arrives at the
    /// cover's root stack.
    ///
    /// The key is therefore caught where it arrives — and **what** it
    /// means is still decided by this window: first the short profile, then
    /// the window. A counter and not a switch, because the same event twice
    /// must act twice.
    var exitToken: Int = 0

    /// Set as soon as the window closes.
    ///
    /// **The guard must then no longer take the focus back.** The window
    /// fades out and lives for a moment while doing so; whoever gives it the
    /// focus back in this time takes it from the page that is just reopening — and that
    /// would then stand without focus, with exactly the consequences the guard was
    /// built against.
    @State private var isClosing = false

    /// The element last grabbed **inside** the window.
    ///
    /// **Focus is returned there, not to the anchor** (viewer finding
    /// 2026-08-12: "click left at Films, and the cursor jumps out of the view"). At the left edge of the tabs there is nothing more, and tvOS keeps
    /// searching — outside, because the sidebar sits in the same frame and is
    /// not disabled. Returning to the invisible anchor would bring the
    /// focus in, but onto something nobody sees: the next press
    /// would lead into the unknown again.
    @State private var lastInside: String?

    /// The self-start in the short profile (AP78): after the dwell time the trailer starts muted in
    /// the place of the poster — the same clock as in the info column, for the same reason.
    @StateObject private var autostart = TrailerAutostart()
    @State private var trailerError: String?
    static let trailerFocusID = "profile-trailer"

    enum Tab: String, CaseIterable {
        case movies
        case series

        var titleKey: String {
            switch self {
            case .movies: "tab.movies"
            case .series: "tab.series"
            }
        }
    }

    init(
        person: Person,
        source: any FilmographySource,
        library: @escaping @Sendable () async -> LibraryIndex,
        exitToken: Int = 0,
        onOpen: @escaping (String) -> Void,
        onClose: @escaping () -> Void,
        onPlay: @escaping (PlaybackTarget) -> Void = { _ in }
    ) {
        _model = StateObject(
            wrappedValue: FilmographyModel(person: person, source: source, library: library))
        self.exitToken = exitToken
        self.onOpen = onOpen
        self.onClose = onClose
        self.onPlay = onPlay
    }

    /// The width of the window.
    ///
    /// A good half of the screen: wide enough for poster, title and three
    /// details side by side, narrow enough that the film behind it stays recognizable as a
    /// film and not as a background image.
    static let width: CGFloat = 1020

    var body: some View {
        ZStack {
            // A dark base over everything: without it, bright list text lies
            // on a bright film scene and cannot be read — the same
            // finding as with the program overlay in the player.
            ColorRole.reason.color.opacity(0.82)
                .ignoresSafeArea()

            panel
                .frame(width: Self.width)
                .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 28))
                // And the rounding applies to the content too: without it the
                // list's last row would push past the bottom edge.
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                // **The anchor catches the focus before the window has content.**
                //
                // Without it the focus stayed on the page below, and
                // you had to press around blindly until it found its way in by chance
                // (viewer finding 2026-08-08). The reason is the known one: on
                // opening, the window shows only a loading spinner, and that takes
                // no focus — a preference among zero candidates stays
                // without effect. The full rationale is at ``FocusAnchor``.
                .focusAnchor(Self.anchorID, focus: $focus)
                // **The Menu button on the panel and not on the stack around it.**
                //
                // Exactly this caused the next finding (2026-08-08): Back did not close the
                // window but left the whole detail page and landed in the overview. On the outer stack the handler
                // is not in the response path of the focused content — the key went
                // past it to the navigation, which also evaluates it.
                // On the panel itself, where the focus sits, it is caught
                // reliably. The same lesson already stands at the player's panels;
                // it cost a whole evening there.
                // **And in two stages, since the short profile exists:** if
                // one is open, the key leads back to the list; only the
                // second press closes the window. A profile that takes the whole
                // filmography with it would be the bug from above one level
                // deeper.
                .onExitCommand(perform: handleExit)
        }
        // **And the same catcher once more on the outer stack** (viewer finding
        // 2026-08-12: "open the filmography in the film and press back, that closes
        // the whole film").
        //
        // Two catchers, one body — and this is not belt and braces,
        // but the answer to two different situations. Where the window stands
        // free, the inner one gets the key and the outer one is silent: the
        // inner one lies deeper and consumes it. Where it lies in a full-screen cover,
        // the key passes the inner one — then the player would otherwise close,
        // and the film is gone.
        //
        // Nested and not side by side, so only one ever fires.
        .onExitCommand(perform: handleExit)
        .task {
            // **Grab the anchor first, then load.** The other way round the
            // focus would stay outside for the duration of the request — and that is exactly when
            // the viewer presses, because they see the window opening.
            takeFocus()
            await model.load()
        }
        // And on to the first tab as soon as there is one: the anchor
        // disappears with the loading state, and whoever still holds it holds
        // something that no longer exists — then tvOS searches for something itself again,
        // and that lies behind the window.
        .onChange(of: model.state) { _, current in
            guard current == .ready, focus == Self.anchorID else { return }
            // **Into the list, not onto the tab** — it no longer exists as a target.
            // If the list stays empty, the anchor keeps holding the focus;
            // a window without focus loses the Menu button.
            guard let first = entries(for: tab).first else { return }
            focus = "entry-" + first.id
        }
        // **And the same for the short profile, because there the list disappears.**
        //
        // Exactly here the regression of 2026-08-11 stood: a press on a foreign
        // row puts the profile in the list's place — the row that held the
        // focus no longer exists afterwards, and in the profile there is nothing to
        // press. Whoever then loses the focus loses the Menu button with it: without a
        // focused element it goes to the navigation, and that closes the
        // detail page or the app outright. Exactly those two pictures were in the
        // test report.
        .onChange(of: model.profile) { _, profile in
            guard let profile else {
                autostart.stop()
                return
            }
            // With a trailer the focus lands on the button — it is the only thing in the profile that
            // does anything. Without one it stays with the anchor as before.
            takeFocus(profile.trailer != nil ? Self.trailerFocusID : nil)
            guard case .youtube(let id, _) = profile.trailer else {
                autostart.stop()
                return
            }
            autostart.configure(
                preferences: TrailerPreferences.load(from: ProfileStore.playback), load: { _ in nil })
            autostart.focus(id: Self.profileID(profile)) {
                try? await TrailerPlayback.youtubeTarget(id, title: profile.title)
            }
        }
        .onDisappear { autostart.stop() }
        .trailerErrorBoard($trailerError)
        // **And the guard for everything else: whatever loses the focus gets it
        // back.**
        //
        // `focus` is this window's state; `nil` therefore does not mean "no
        // focus" but "the focus is outside" — on the disabled page
        // below or, because it sits to the left in the same frame, in the
        // sidebar. That is the state in which the Menu button no longer arrives at this
        // window's catcher: in the sidebar it leads one level
        // out and, on "Library", straight out of the app; in the frame the
        // navigation path takes it and closes the detail page. Both pictures are in
        // the test report of 2026-08-11.
        .onChange(of: exitToken) { _, _ in handleExit() }
        .onChange(of: focus) { _, current in
            if let current {
                lastInside = current
                return
            }
            guard !isClosing else { return }
            takeFocus(lastInside)
        }
        // Observes only — see ``focusTrail(_:_:)``.
        .focusTrail("Filmografie", focus)
    }

    /// What the Menu button does: **first the short profile, then the window.**
    ///
    /// A profile that takes the whole filmography with it would be the known bug
    /// one level deeper — hence two stages.
    private func handleExit() {
        if model.closeProfile() {
            takeFocus()
            return
        }
        close()
    }

    /// Closes the window — and notifies the guard.
    private func close() {
        isClosing = true
        onClose()
    }

    /// The identifier of this window's focus anchor.
    static let anchorID = "filmography-anchor"

    /// Brings the focus into the window — **and follows up.**
    ///
    /// **A single assignment is not enough, and this is verified on the device**
    /// (E20, four times): tvOS assigns the focus itself during the rebuild, and whoever assigns
    /// beforehand is overwritten. If the focus is outside the window afterwards,
    /// the Menu button passes the panel's catcher — it reaches
    /// the navigation, and you lose the detail page or the app.
    ///
    /// The check is for **any** target in the window and not for the anchor: the
    /// focus may well sit on a tab or a row, it just should not
    /// be outside. `focus` is this window's state — if it is
    /// `nil`, nothing from here holds it.
    private func takeFocus(_ wanted: String? = nil) {
        let target = wanted ?? Self.anchorID
        focus = target

        let startedAt = Date()
        Task { @MainActor in
            // First wait, then check: a focus just written reads back
            // immediately, even if tvOS never accepted it.
            for attempt in 1...6 {
                try? await Task.sleep(for: .milliseconds(50))
                if focus != nil { return }
                // And the operator beats the follow-up (AP4 · K7).
                if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) {
                    return
                }
                // On the third attempt fall back to the anchor: the remembered
                // element may no longer exist — a row that vanished on a
                // tab switch no longer accepts focus,
                // and continuing to point at it would mean never coming back.
                focus = attempt < 3 ? target : Self.anchorID
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            switch model.state {
            case .loading:
                notice { ProgressView() }

            case .failed(let key):
                notice {
                    Text(appKey: key)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .multilineTextAlignment(.center)
                }

            case .ready:
                // **The profile stands in place of the list, not above it.** The
                // full rationale is at ``FilmographyModel/profile``.
                if let profile = model.profile {
                    profilePanel(profile)
                } else {
                    tabs
                    list
                }
            }
        }
        .padding(.vertical, 34)
    }

    // MARK: - Short profile

    /// What the film database knows about a title you do not have.
    ///
    /// **Without a button and without a focus target.** There is nothing to press here — the
    /// way back is the Menu button, and the panel catches that anyway. A
    /// focusable element that does nothing would be a promise without delivery.
    /// So that the Menu button arrives, the window's anchor holds the focus (see
    /// ``FocusAnchor``) — the same lesson as with the program overlay in the
    /// player, where without held focus no key arrived at all any more.
    private func profilePanel(_ profile: TitleProfile) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                // The trailer in the place of the poster, faded over — as in the
                // library's info column (``DetailColumn``).
                ZStack(alignment: .topLeading) {
                    if let running = autostart.running,
                        running.itemID == Self.profileID(profile)
                    {
                        TrailerSurface(target: running.target)
                            .transition(.opacity)
                    } else {
                        RemoteImage(url: profile.posterURL, displaySize: Self.profilePosterSize)
                            .frame(
                                width: Self.profilePosterSize.width,
                                height: Self.profilePosterSize.height
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: autostart.running?.itemID)

                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: profile.title)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)

                    Text(verbatim: Self.facts(profile))
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(2)

                    if let trailer = profile.trailer {
                        trailerButton(trailer, profile: profile)
                    }

                    if profile.overview.isEmpty {
                        Text(app: "filmography.noOverview")
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    } else {
                        Text(verbatim: profile.overview)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.text.color)
                            .lineSpacing(4)
                    }

                    if !profile.cast.isEmpty {
                        Text(verbatim: profile.cast.joined(separator: " · "))
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .lineLimit(2)
                    }

                    Text(app: "filmography.backToList")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
        }
        .frame(height: 620)
    }

    /// The trailer button in the short profile (AP78) — the same as on the detail page, with
    /// a language badge. For a title that is not in the catalog it is the only thing that
    /// can be played here.
    private func trailerButton(_ trailer: TrailerChoice, profile: TitleProfile) -> some View {
        let focused = focus == Self.trailerFocusID
        return Button {
            Task {
                if let target = await trailerDestination(trailer, profile: profile) {
                    autostart.stop()
                    onPlay(target)
                } else {
                    trailerError = trailer.youtubeID ?? ""
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "film")
                Text(app: "detail.trailer")
                if let badge = trailer.badge {
                    LanguageBadge(badge, bright: focused)
                }
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(focused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .background(
                focused ? ColorRole.text.color : ColorRole.surfaceHigh.color, in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: Self.trailerFocusID)
        .focusHighlight(focused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
        .info(appKey: "detail.trailer")
    }

    /// If the trailer already plays muted in the profile, its address is the button's — no
    /// second resolution at YouTube.
    private func trailerDestination(_ trailer: TrailerChoice, profile: TitleProfile) async -> PlaybackTarget?
    {
        if let running = autostart.running, running.itemID == Self.profileID(profile) {
            return running.target
        }
        guard case .youtube(let id, _) = trailer else { return nil }
        return try? await TrailerPlayback.youtubeTarget(id, title: profile.title)
    }

    static func profileID(_ profile: TitleProfile) -> String {
        "profil-" + profile.title + "-" + (profile.year.map(String.init) ?? "")
    }

    static let profilePosterSize = CGSize(width: 220, height: 330)

    /// Year, genres and rating as one line — empty entries are dropped
    /// so that no lonely separators are left standing.
    static func facts(_ profile: TitleProfile) -> String {
        var parts: [String] = []
        if let year = profile.year { parts.append(String(year)) }
        if !profile.genres.isEmpty { parts.append(profile.genres.prefix(3).joined(separator: ", ")) }
        if let rating = profile.rating, rating > 0 {
            parts.append(String(format: "%.1f", rating))
        }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: model.person.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
            if let character = model.person.character, !character.isEmpty {
                Text(verbatim: character)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 22)
    }

    /// A notice centered in the window — for waiting and for information.
    ///
    /// With a fixed height so that the window does not jump when switching from "loading" to
    /// "done".
    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 420)
        .padding(.horizontal, 40)
    }

    // MARK: - Tabs

    /// The tabs — **a display and not a target** (user request 2026-08-12).
    ///
    /// **They say where you are; switching happens sideways.** Left and right have
    /// switched between films and series since E19 anyway, from within the
    /// list. That made the path via the tabs the longer one for the same
    /// thing: up, sideways, back down — three presses for one.
    ///
    /// **And a focus target that can do nothing its neighbor cannot also do
    /// costs more than it brings.** It lies at the top edge of the window: whoever
    /// stands there and keeps pressing finds nothing, and the focus leaves
    /// the window — exactly the path the viewer reported as "the cursor jumps
    /// out". Without focusable tabs this edge no longer exists;
    /// the list is the only place where the focus can stand.
    private var tabs: some View {
        HStack(spacing: 12) {
            ForEach(Tab.allCases, id: \.rawValue) { entry in
                let isSelected = tab == entry

                HStack(spacing: 10) {
                    Text(appKey: entry.titleKey)
                        .font(TypeLevel.footer.font)
                    // The count right alongside: an empty tab is recognized
                    // faster that way than by going into it.
                    Text(verbatim: "\(entries(for: entry).count)")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(
                            isSelected ? ColorRole.reason.color : ColorRole.textQuiet.color)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                // **The selected tab carries the full highlight.** It is
                // now the only place saying which list you see —
                // before, it shared this task with the focus, and
                // the same capsule could mean two things.
                .background(
                    isSelected ? ColorRole.text.color : ColorRole.reason.color.opacity(0.35),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? ColorRole.reason.color : ColorRole.textMatt.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
        // Nothing here takes focus — so there is nothing to hit either. The
        // section that held the path between tabs and list just now has been
        // dropped along with the buttons.
        .accessibilityElement(children: .combine)
    }

    private func entries(for tab: Tab) -> [FilmographyEntry] {
        switch tab {
        case .movies: model.filmography.movies
        case .series: model.filmography.series
        }
    }

    // MARK: - List

    private var list: some View {
        let shown = entries(for: tab)

        return ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 8)
        }
        .frame(height: 620)
        // **Explicitly WITH clipping**, unlike the app's rows.
        //
        // `scrollClipDisabled` stood here, out of habit: grid tiles grow
        // beyond their frame on focus and would otherwise be cut off. A
        // row in this window does not grow, it only turns bright — instead the list scrolled
        // unhindered over the header and tabs, and the person's name
        // lay under a film poster (viewer finding 2026-08-08).
        .focusSection()
        // **Left and right switch the tab** (test report 2026-08-08): whoever stands in
        // the list and wants to go to the series first had to go up to the
        // tabs, sideways there and back down — three moves for one
        // switch, which the remote can do in one press. The rows themselves
        // do not need the sideways direction: they span the full width.
        .onMoveCommand { direction in
            // See AP4 · K7 — the mark next to the trace line.
            lastInputAt = Date()
            Diagnostics.cursorKey("Filmografie", FocusTrail.name(direction))
            guard let next = Self.tab(from: tab, moving: direction) else { return }
            tab = next
            // The focus moves along into the new list. Without this line it would stay
            // on a row that no longer exists — and tvOS then puts it
            // somewhere.
            //
            // **And never to `nil`.** If the target tab is empty — a person
            // with films but no series —, the computation used to deliver
            // nothing. Without a focused element the Menu button passes the panel's
            // catcher to the navigation, and then the detail page or the app
            // closes. The anchor holds the focus until there are rows again —
            // the same answer that the end of loading above already gives.
            focus = Self.focusAfterTabChange(firstEntryID: entries(for: next).first?.id)
        }
    }

    /// The tab a sideways press leads to — `nil` means: do nothing.
    ///
    /// Stands as a pure computation next to the view, like the other focus paths
    /// (see ``FocusRules``). **Without wrap-around:** two tabs, and whoever
    /// stands on the right and keeps pressing right does not mean "start over" — they
    /// mean nothing at all, and then standing still is the right answer.
    static func tab(from current: Tab, moving direction: MoveCommandDirection) -> Tab? {
        switch (direction, current) {
        case (.right, .movies): .series
        case (.left, .series): .movies
        default: nil
        }
    }

    /// Where the focus belongs after a tab switch — **never to `nil`**.
    ///
    /// Stands as a pure computation next to the view, like ``tab(from:moving:)``.
    /// An empty tab is the regular case and not the exception: the
    /// tab row shows both tabs with their count, even if it is
    /// zero. Without a focused element tvOS no longer delivers movement commands
    /// and gives the Menu button to the system.
    ///
    /// The anchor holds in every state of this window: its modifier hangs
    /// unconditionally on the panel, not in a branch and not on a loading state.
    static func focusAfterTabChange(firstEntryID: String?) -> String {
        firstEntryID.map { "entry-" + $0 } ?? anchorID
    }

    private func row(_ entry: FilmographyEntry) -> some View {
        let id = "entry-" + entry.id
        let isFocused = focus == id

        return Button {
            // **What you have opens; what you do not have explains itself.**
            //
            // The earlier decision (2026-08-08) was not to let foreign rows respond at all
            // — a button that does nothing on two thirds of the rows would be worse than a row
            // without a button. The objection was right, the answer was just the smaller of two:
            // now the foreign row responds too, with what the film database
            // knows about it (roadmap P17).
            if let itemID = entry.libraryItemID {
                // Via ``isClosing``, so that the focus guard lets the window
                // go: the target's detail page appears in a moment, and it
                // needs the focus.
                isClosing = true
                onOpen(itemID)
            } else {
                Task { await model.showProfile(for: entry) }
            }
        } label: {
            content(entry, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
    }

    private func content(_ entry: FilmographyEntry, isFocused: Bool) -> some View {
        HStack(spacing: 20) {
            RemoteImage(url: entry.posterURL, displaySize: Self.posterSize)
                .frame(width: Self.posterSize.width, height: Self.posterSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.title)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let role = entry.role {
                    Text(verbatim: role)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(
                            isFocused ? ColorRole.reason.color.opacity(0.7) : ColorRole.textMatt.color
                        )
                        .lineLimit(1)
                }

                HStack(spacing: 14) {
                    // Without a year means: not yet released. It is shown as a word
                    // and not as a gap — a gap would look like a
                    // missing value.
                    if let year = entry.year {
                        Text(verbatim: String(year))
                    } else {
                        Text(app: "filmography.announced")
                    }

                    if let rating = entry.rating {
                        Text(verbatim: String(format: "★ %.1f", rating))
                    }
                }
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(
                    isFocused ? ColorRole.reason.color.opacity(0.7) : ColorRole.textQuiet.color
                )
            }

            Spacer(minLength: 0)

            // **The attribute for the sake of which TMDb is needed at all.**
            // Only on what exists: a mark on every row that
            // mostly says "no" would be noise — the rare thing should stand out.
            if entry.isInLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(
                        isFocused ? ColorRole.reason.color : Color(palette, .bright)
                    )
                    .accessibilityLabel(Text(app: "filmography.inLibrary"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
        .background(
            isFocused ? ColorRole.text.color : ColorRole.reason.color.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    /// The poster in the row — upright as everywhere, only small.
    static let posterSize = CGSize(width: 88, height: 132)
}

/// What the filmography needs, passed in instead of obtained itself.
///
/// **The same pattern as ``LivePlayerContext``, and for the same reason:** the
/// detail page and the player know neither a film database nor the way to
/// another title. They get both from outside — and where it is missing,
/// the filmography simply does not exist, while everything else runs unchanged.
/// Without this detour each of the two views would carry a service that has nothing to do
/// with its job.
public struct FilmographyContext {

    let source: any FilmographySource
    /// The own catalog for the comparison — as a question and not as a
    /// snapshot, so that it is collected only when someone needs it.
    let library: @Sendable () async -> LibraryIndex
    /// Opens a title of the own library via its identifier.
    let open: @MainActor (String) -> Void
    /// Shows a person's career — **and does so where the window
    /// belongs, not where the name stands.**
    ///
    /// The detail page only says *whom* it got pressed; the
    /// window is built by ``MainView``. The reason is stated there and is verified in the simulator:
    /// inside a navigation path the window's catcher does not get
    /// the Menu button — the path evaluates it itself beforehand and leaves
    /// the detail page.
    let show: @MainActor (Person) -> Void

    public init(
        source: any FilmographySource,
        library: @escaping @Sendable () async -> LibraryIndex,
        open: @escaping @MainActor (String) -> Void,
        show: @escaping @MainActor (Person) -> Void = { _ in }
    ) {
        self.source = source
        self.library = library
        self.open = open
        self.show = show
    }
}
