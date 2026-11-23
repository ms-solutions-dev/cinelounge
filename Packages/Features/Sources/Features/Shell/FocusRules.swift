import Core
import Foundation

/// Where the focus goes — as a rule, not as the behaviour of a view.
///
/// **Why this lives here and not in the views.** tvOS picks its focus target
/// by **geometry**, not by meaning: what lies diagonally to the left is not found when
/// pressing up; what lies directly below always wins — even if
/// it is the wrong season. The only way to fix that is to set the paths
/// explicitly.
///
/// Explicitly set paths are only as good as their rationale, and in
/// a SwiftUI view that rationale is nowhere verifiable. That is why the rules
/// live here as pure functions: **they are pinned down with tests**, and the
/// views follow them instead of containing them. What is correct today cannot
/// be broken by accident by the next change.
///
/// ## The plan, area by area
///
/// **Sidebar.** You enter from the left; you arrive on the entry
/// of the open area (``AppSidebar/mainEntry(for:)``) — not where the
/// geometry points. You leave with the menu button, and **one step per
/// press**: group → provider → Live → Library. The ladder ends at "Library";
/// there the button belongs to tvOS, and a press leaves the app.
///
/// **Library.** The pill divides it into Home, Series, Movies, Home Videos.
/// "Library" in the sidebar **always leads to the Home screen** — whoever selects
/// the area means its beginning, not the place where they
/// left off. Leaving works step by step: from the grid to the pill, from
/// the pill to the sidebar.
///
/// **Detail page of a series.** Down from the play button leads to the
/// season you are in — not to the one that happens to lie below. Up
/// from a season leads back to the play button.
/// ## Why public
///
/// Because ``LibraryView`` is: The ladder appears in its build instruction
/// (`exitLadder`), and a public declaration cannot carry an internal type.
/// That makes exactly the vocabulary visible that the views speak anyway —
/// the rules of the individual areas below stay internal.
public nonisolated enum FocusRules {}

// MARK: - The stairs out of a content area

nonisolated extension FocusRules {

    /// A station on the way out of a content area.
    ///
    /// **A ladder and not a door**, and that is the most expensive finding of the
    /// test days: a Back that closes the whole app straight from the grid
    /// costs more than any inconvenient list — you lose focus, position and
    /// loading state with a single press.
    public enum ExitStep: Equatable, Hashable, Sendable {
        /// A detail page lies on top — it goes first.
        case detailPage
        /// Back to the start of the list, scrolled all the way to the top.
        case topOfList
        /// **One level back** — the navigation path becomes shorter by its last
        /// entry.
        ///
        /// **The step that was missing** (viewer finding 2026-08-27: no way back out of
        /// Most Watched). In the portals the path
        /// leads arbitrarily deep — entry, genre, series, season —, and the
        /// menu button went from any depth straight into the sidebar: The
        /// innermost catcher consumed it, the navigation path never got to
        /// see it, and `paths` stayed untouched.
        ///
        /// It sits **before** ``sidebar`` and **after** ``topOfList``: First unwind
        /// the path, and only when the path is empty leave the area.
        case level
        /// Into the pill of the Library.
        case pill
        /// Into the sidebar, onto the entry of the open area. From there
        /// ``AppSidebar/Destination/stepOut`` leads on.
        case sidebar
    }

    /// The next step out: the first station of the ladder that is still pending.
    ///
    /// **One rule for all areas, not a similar one per area.** That is
    /// exactly what the finding of 2026-08-11 hinged on: For the Library the ladder was
    /// built in E16, the provider Library lacked it — and there Back
    /// between the posters closed the whole app. Two areas, two ladders, but
    /// **one** procedure: The stations are listed from inside to outside, and whichever is
    /// still pending comes next.
    ///
    /// `nil` means: All stations are behind us. Then the menu button belongs to
    /// tvOS — and that is the case that must not be intercepted, see
    /// ``AppSidebar/Destination/stepOut``.
    public static func stepOut(along ladder: [ExitStep], pending: Set<ExitStep>) -> ExitStep? {
        ladder.first(where: pending.contains)
    }

    /// The ladder of the Library (E16): detail page → pill → sidebar.
    public static let mediaLadder: [ExitStep] = [.detailPage, .pill, .sidebar]

    /// The ladder of the provider Library: start of list → sidebar.
    ///
    /// Two steps instead of three, and both differences have a reason: There is no
    /// detail page there — the selection plays —, and no pill either. In return the start has
    /// the step that the Library does not need: It has the pill above the grid, here the start of the list
    /// is the first resting point (user requirement 2026-08-11).
    public static let vodLadder: [ExitStep] = [.topOfList, .sidebar]

    /// The ladder of a portal: start of list → one level back →
    /// sidebar.
    ///
    /// **The ladder of the provider Library extended by one step, and by exactly
    /// that one.** A provider has nothing below the category — the
    /// selection plays. A portal has arbitrarily many levels below it,
    /// and without ``ExitStep/level`` the menu button jumped from the third level straight
    /// into the sidebar (viewer finding 2026-08-27).
    ///
    /// That it lives here and not in a closure in ``MainView`` is the
    /// point: Yesterday's attempt lived in a callback, was therefore not
    /// verifiable — and did not hold up on the device.
    public static let portalLadder: [ExitStep] = [.topOfList, .level, .sidebar]

    // MARK: - The follow-up grabs

    /// Whether a focus follow-up is to be abandoned because the operator has done
    /// something themselves.
    ///
    /// **A follow-up that stops against a key press is worse than
    /// a swallowed press** (finding K7, 2026-08-24). Five passes of 50 ms
    /// reset the focus for a quarter of a second: The viewer sees
    /// their movement happen — and undone again. So far it was cancelled
    /// only by a competing jump, never by an
    /// input.
    ///
    /// **The leniency is necessary because the press comes after the focus.** A
    /// follow-up usually starts from `onChange(of: focus)`, and the matching
    /// move command only arrives afterwards (focus trace 2026-08-12: the key press
    /// appears three milliseconds AFTER the focus change). Without leniency
    /// every follow-up would be cancelled by exactly the press it was started for.
    ///
    /// Upwards there is plenty of room: Even the held button repeats only
    /// after about 100 ms, and two separately made presses are far above that.
    /// What arrives between 20 and 250 ms is the operator and not the
    /// trigger.
    static func abandonsRetry(
        startedAt: Date, lastInput: Date, grace: TimeInterval = retryInputGrace
    ) -> Bool {
        lastInput.timeIntervalSince(startedAt) > grace
    }

    /// Siehe ``abandonsRetry(startedAt:lastInput:grace:)``.
    static let retryInputGrace: TimeInterval = 0.02
}

extension AppSidebar.Destination {

    /// One step out of the sidebar. `nil` means: **this is the end.**
    ///
    /// **And `nil` is the most important case.** On tvOS the menu button at
    /// the topmost position leaves the app — that is expected behaviour and the only
    /// place where we must not intercept it. Until now it was intercepted one level
    /// too high: The catcher hung on the whole sidebar section, and
    /// because an attached `onExitCommand` consumes the button even when
    /// its body does nothing, it was simply ineffective on "Library". You could
    /// only get out via the Home button.
    ///
    /// That is why the rule lives here as a value and not as an `if` in the view:
    /// Each row attaches its catcher according to **its own** identifier, and the
    /// "Library" row attaches none at all.
    var stepOut: AppSidebar.Destination? {
        switch self {
        // With the provider level the ladder has one more step:
        // group → provider → Live → Library.
        case .liveProviderGroup(let provider, _): .liveProvider(provider)
        case .liveProvider: .live
        case .liveGroup: .live
        // And the same for Movies & Series: category → provider does not exist,
        // because the category lives in the surface. Both lead up one step.
        case .vodProvider: .vod
        // Portals likewise: a portal leads to "Portals", from there to
        // "Library". Two steps as everywhere else.
        case .portalProvider: .portals
        case .search, .favorites, .live, .vod, .sport, .portals, .settings, .sync,
            .accounts:
            .media
        case .media, .jellyfin: nil
        }
    }
}

extension AppSidebar {

    /// How long the wrap-around waits to see whether the press does have an effect after all.
    ///
    /// **The value was 320 ms, and that was a third of a second too much**
    /// (viewer finding 2026-08-22: "the jump from the very top to the bottom … does not
    /// feel smooth"). Re-measured in the focus trace of the same
    /// session, sidebar with eight entries:
    ///
    /// ```
    /// 22:59:21.349  sync → settings        123 ms   ← one row further
    /// 22:59:21.418  ↓                                ← press at the bottom edge
    /// 22:59:22.080  settings → media       662 ms   ← the wrap-around
    /// ```
    ///
    /// An ordinary step costs 76 to 150 ms, the wrap-around 359 ms upwards
    /// and 662 ms downwards. The difference is exactly what feels
    /// choppy.
    ///
    /// **Why the 320 ms were necessary back then — and no longer are:** On 12.08.
    /// ``isEdgePress(lastFocusMove:now:)`` did not exist yet. Back then the
    /// press that had only just moved the focus ONTO the edge also planned a wrap-around; for that one the move from tvOS arrived
    /// about 260 ms later and
    /// pushed on from the new end — the double jump. Since 16.08. the edge-press test
    /// catches this press **before** anything is planned at all. Since then the wait has secured a case that no longer exists.
    ///
    /// Checked whether anything still follows at the real edge: In the trace of
    /// 22.08. there is **not a single** focus change from tvOS between the edge press and
    /// our wrap-around — neither at the top (`media`, 18:092 → 18:451) nor at the bottom
    /// (`settings`, 21:418 → 22:080). At the edge tvOS moves nothing, because there is
    /// nothing to move.
    ///
    /// What remains is 60 ms: short enough to stay below the ordinary step,
    /// and long enough that the safeguard `focus == on` can still
    /// check something if a move does come.
    static let wrapDelay = 60

    /// Whether a move command is a real edge press — or the straggler
    /// of a press that the focus has long since consumed itself.
    ///
    /// **The viewer's numbers gave it away** (2026-08-16): Seven
    /// entries, every sixth press a double; eight entries, every seventh —
    /// exactly the press that **lands** on the LAST entry doubles.
    /// `onMoveCommand` reports only AFTER the native focus step
    /// (measured 2026-08-12: +4–180 ms). The press that leads to the last element
    /// therefore already sees "focus is at the edge" in the handler, plans the
    /// wrap-around — and that fires a third of a second later without a new press:
    /// two movements for one press, deterministically at every
    /// wrap-around point. A command whose focus has only just moved is
    /// this straggler and plans NOTHING.
    ///
    /// The threshold lies above the measured 180 ms lag and below every
    /// real second press (the remote's repeat rate of ~100 ms applies to the
    /// HELD button — its commands move the focus themselves and thus each carry
    /// a fresh timestamp; single presses are far more than
    /// a quarter of a second apart).
    static func isEdgePress(lastFocusMove: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastFocusMove) > consumedPressWindow
    }

    /// Siehe ``isEdgePress(lastFocusMove:now:)``.
    static let consumedPressWindow: TimeInterval = 0.25

    /// The entry that a press beyond the edge leads to.
    ///
    /// **tvOS has no natural wrap-around.** Whoever stands at the bottom on Settings
    /// and keeps pressing stays where they are — and keeps pressing until they take the app
    /// for hung. The channel list in the player has wrapped since 2026-08-10;
    /// the sidebar did not.
    ///
    /// **Only what the focus has not consumed arrives here** — that is,
    /// exactly the press beyond the end. Within the sidebar tvOS moves
    /// by itself, and this rule changes nothing about that.
    static func wrapped(
        from current: Destination?, by offset: Int, in rows: [Destination]
    )
        -> Destination?
    {
        guard rows.count > 1, let current, let index = rows.firstIndex(of: current)
        else { return nil }
        // **Only at the edge, and that is the whole point.** `onMoveCommand` arrives
        // even when the focus has already moved — the assumption that it
        // reported only unconsumed movements was wrong (viewer finding
        // 2026-08-11: "I press down once and it jumps twice"). In the middle of
        // the list the focus moves by itself, and nothing may
        // happen here; only at the end, where it would stay put, is there a wrap-around.
        if offset > 0, index == rows.count - 1 { return rows[0] }
        if offset < 0, index == 0 { return rows[rows.count - 1] }
        return nil
    }
}

extension DetailModel {

    /// The season with which a series opens.
    ///
    /// **Until now it was always the first, and that was the mistake.** For "The Flaihuski
    /// Freipri Taspreis", "down" from the play button led to season 2 every time,
    /// because it lay directly below — whoever is at season 6 had to
    /// navigate there every time. Geometry was only half the cause: The other
    /// was that the page opened at season 1 in the first place.
    ///
    /// **What is wanted is the season you are in** — the first with
    /// something still unseen. If everything is seen, it is the last: Whoever has finished
    /// a series looks for the newest episode and not the oldest. If the server
    /// says nothing about progress, it stays with the first.
    ///
    /// Without actor binding, because it is a pure computation over values — that way
    /// it can be tested without involving the main thread.
    ///
    /// **Since AP58 R6 the rule lives in ``Core/ContinueWatching/startSeason(in:pending:)``** —
    /// the phone has since also opened the last season when everything is seen. Specials
    /// (season 0) no longer open the page since 2026-09-27.
    public nonisolated static func startingSeason(in seasons: [MediaItem]) -> MediaItem? {
        ContinueWatching.startSeason(
            in: seasons, number: ContinueWatching.seasonNumber, pending: \.unplayedCount)
    }
}

extension DetailView {

    /// The season that the **entry** into the season row leads to.
    ///
    /// **Two requests to tvOS were not enough, and the finding says exactly
    /// why** (on-device test 2026-08-11): From the play button downwards the focus landed
    /// not on some wrong season but **always on the second** —
    /// the one that lies geometrically below the button. `defaultFocus` and
    /// `prefersDefaultFocus` say which target is preferred; the system
    /// has one here and takes it.
    ///
    /// **So it is corrected instead of requested.** By the time the key press arrives
    /// the focus has long since moved — the lesson from E20 —, so this
    /// rule hangs not on the press but on the focus change itself: If the focus comes from
    /// **outside** the row (button row, episodes, sidebar), nobody
    /// chose a season, the geometry assigned one — then
    /// the focus belongs on the season you are in.
    ///
    /// `nil` means: **nothing to correct.** Whoever moves within the row
    /// has chosen and is left undisturbed; whoever already stands correctly is not
    /// set again — a second assignment to the same identifier would be a
    /// focus change without movement and would drive the follow-up into a loop.
    ///
    /// A pure computation over values — like the tab rule of the filmography, and
    /// thus testable without a running view.
    static func seasonOnEntry(
        previous: String?, current: String?, selected: String?
    ) -> String? {
        guard let current, current.hasPrefix(seasonPrefix) else { return nil }
        // Moved within the row: That is a choice, not an assignment.
        if let previous, previous.hasPrefix(seasonPrefix) { return nil }
        guard let selected else { return nil }
        let wanted = seasonPrefix + selected
        return wanted == current ? nil : wanted
    }

    /// The episode that an entry into the row belongs on.
    ///
    /// **One answer for all ways in** — the press down from the
    /// season, the pre-hold of the highlight and the correction. Two
    /// answers to the same question diverged in the first rebuild,
    /// and then the button started a different episode than the focus showed.
    ///
    /// **Remembered beats continue-episode** (finding K6): Whoever has paged through 62
    /// episodes and seen one means the sixty-second on coming back
    /// and not the seventh. A remembered episode from a
    /// different season is not in the row at all and therefore does not count —
    /// that is at the same time the entire invalidation on a season change.
    static func episodeEntry(
        episodes: [String], resuming: String?, remembered: String?
    ) -> String? {
        if let remembered, episodes.contains(remembered) { return remembered }
        guard let resuming, episodes.contains(resuming) else { return nil }
        return resuming
    }

    /// The episode that the **entry** into the episode row leads to.
    ///
    /// **The same disease one row deeper** (user finding 2026-08-12): Blibiagraik has
    /// over 300 episodes in season 1, so you would otherwise have to press forward endlessly.
    /// Whoever comes down from the season landed on the first episode because it
    /// stands on the left; what is meant is the one where you were last.
    ///
    /// **And exactly the one that the play button starts.** Which that is,
    /// ``DetailModel/playbackTarget`` already computes — started ones first,
    /// then the first unseen. It is simply not determined a second time here:
    /// Two answers to the same question diverged in the first rebuild,
    /// and then the button started a different episode than the focus
    /// showed.
    ///
    /// The episodes carry their own identifier and no prefix — what marks an entry
    /// is therefore told by the list itself and not by the name.
    ///
    /// **And a return is not an entry** (finding K6, device 2026-08-24: 62
    /// episodes paged through, one seen, menu button — back at the start). The
    /// player lies as a full screen over this page; while it is up, the page has
    /// no focus, and on coming back `previous` is therefore `nil` as with
    /// every entry from outside. From `previous` alone the two cannot be
    /// told apart — but they can from `remembered`: Whoever has already stood in this
    /// row returns there, just as `focusBeforeFilmography` does
    /// for the career.
    static func episodeOnEntry(
        previous: String?, current: String?, episodes: [String], resuming: String?,
        remembered: String?
    ) -> String? {
        guard let current, episodes.contains(current) else { return nil }
        // Moved within the row: That is a choice, not an assignment.
        if let previous, episodes.contains(previous) { return nil }
        guard
            let wanted = episodeEntry(episodes: episodes, resuming: resuming, remembered: remembered),
            wanted != current
        else { return nil }
        return wanted
    }
}

nonisolated extension SettingsSection {

    /// The area that a press beyond the edge leads to.
    ///
    /// **The same rule as in the sidebar, and for the same reason** (see
    /// ``AppSidebar/wrapped(from:by:in:)``): tvOS has no natural
    /// wrap-around. Whoever stands at the bottom on "Account" and keeps pressing stays where they are —
    /// and keeps pressing until they take the app for hung
    /// (user requirement 2026-08-11: wrapping from the bottom exactly like pressing up at the top).
    ///
    /// **Only at the edge.** `onMoveCommand` arrives even when the focus has
    /// already moved; in the middle of the list it moves by itself, and nothing
    /// may happen here. Otherwise it jumps twice per press — the finding of
    /// 2026-08-11, from which the sidebar learned the same lesson.
    ///
    /// `nil` therefore means: **nothing to do here**, not "does not work".
    static func wrapped(from current: SettingsSection?, by offset: Int) -> SettingsSection? {
        let rows = allCases
        guard rows.count > 1, let current, let index = rows.firstIndex(of: current)
        else { return nil }
        if offset > 0, index == rows.count - 1 { return rows[0] }
        if offset < 0, index == 0 { return rows[rows.count - 1] }
        return nil
    }
}
