import Core
import Foundation
import Testing

@testable import Features

/// **The focus paths as a rule, written down.**
///
/// P14 explicitly demands writing them down once in context instead of patching case by case
/// — and holding on to what was written down, "otherwise the next change breaks it again".
/// That is exactly what these checks stand for: Where the focus goes is here a statement
/// about values and not about a view, and thus verifiable.
@Suite("Fokuswege")
/// On the main actor, because the rules being checked live there (AP15, 2026-09-02): The warning
/// gate turns "nonisolated calls MainActor" into a failure — and that is what it always was
/// in substance.
@MainActor
struct FocusRulesTests {

    // MARK: - The stairs out of the sidebar

    /// **The case that triggered P14 in the first place.** On "Mediathek" it ends: There the
    /// menu button belongs to tvOS, and a press leaves the app. Until now it was intercepted one
    /// level too high and was simply ineffective there — you only got out via the Home button.
    @Test("On the top level the Menu button belongs to tvOS")
    func topLevelHandsTheKeyBack() {
        #expect(AppSidebar.Destination.media.stepOut == nil)
    }

    @Test("Every other level leads out exactly one step")
    func everyLevelStepsOutOnce() {
        #expect(AppSidebar.Destination.search.stepOut == .media)
        #expect(AppSidebar.Destination.favorites.stepOut == .media)
        #expect(AppSidebar.Destination.settings.stepOut == .media)
        #expect(AppSidebar.Destination.live.stepOut == .media)
        #expect(AppSidebar.Destination.vod.stepOut == .media)

        #expect(AppSidebar.Destination.liveGroup("TR · Genel").stepOut == .live)
        #expect(AppSidebar.Destination.vodProvider("liste").stepOut == .vod)
    }

    /// With one more stored list the staircase becomes one step longer:
    /// group → provider → Live → Mediathek.
    @Test("The provider level inserts one step, not two")
    func providerLevelAddsOneStep() {
        let group = AppSidebar.Destination.liveProviderGroup(provider: "A", group: "News")

        #expect(group.stepOut == .liveProvider("A"))
        #expect(group.stepOut?.stepOut == .live)
        #expect(group.stepOut?.stepOut?.stepOut == .media)
        #expect(group.stepOut?.stepOut?.stepOut?.stepOut == nil)
    }

    /// **Every staircase ends, and it ends at the same place.** A target that leads in a circle
    /// or never arrives could not be noticed by hand — you press three times and take it for a
    /// deep nesting.
    @Test("Every way out ends on the library")
    func everyPathTerminates() {
        let all: [AppSidebar.Destination] = [
            .media, .search, .favorites, .live, .vod, .settings, .sync,
            .liveGroup("g"), .liveProvider("p"),
            .liveProviderGroup(provider: "p", group: "g"),
            .portals, .portalProvider("serieshub"),
        ]

        for start in all {
            var current = start
            var steps = 0
            while let next = current.stepOut {
                current = next
                steps += 1
                #expect(steps <= 4, "\(start) does not lead out")
            }
            #expect(current == .media, "\(start) ends on \(current)")
        }
    }

    // MARK: - The stairs out of a content section

    /// **The costliest single finding of the on-device test of 2026-08-11:** Whoever scrolled among
    /// the posters in the provider library and pressed Back was out — out of the whole app. What
    /// is wanted is steps, and the same ones the Mediathek has had since E16.
    @Test("The provider library leads out step by step, not in one press")
    func vodLeavesInSteps() {
        // In the middle of the list: first to its start.
        #expect(
            FocusRules.stepOut(along: FocusRules.vodLadder, pending: [.topOfList, .sidebar])
                == .topOfList
        )
        // Arrived at the start: into the sidebar.
        #expect(
            FocusRules.stepOut(along: FocusRules.vodLadder, pending: [.sidebar]) == .sidebar
        )
    }

    /// The staircase of the Mediathek, as it was built in E16 — written down here as a rule,
    /// because it has been used by two sections since AP2.
    @Test("The library goes detail page, pill, bar")
    func mediaLeavesInSteps() {
        #expect(
            FocusRules.stepOut(
                along: FocusRules.mediaLadder, pending: [.detailPage, .pill, .sidebar]
            ) == .detailPage
        )
        #expect(
            FocusRules.stepOut(along: FocusRules.mediaLadder, pending: [.pill, .sidebar])
                == .pill
        )
        #expect(
            FocusRules.stepOut(along: FocusRules.mediaLadder, pending: [.sidebar]) == .sidebar
        )
    }

    /// **The order comes from the staircase, not from the way of asking.** If it stood in the
    /// condition of the view, the order of the `if`s would decide there — and at the next
    /// rework that is a different one.
    @Test("A step that does not exist in this staircase is skipped")
    func unknownStepsAreSkipped() {
        // The provider library has neither a detail page nor a pill; even if both were pending, its
        // first step is the start of the list.
        #expect(
            FocusRules.stepOut(
                along: FocusRules.vodLadder, pending: [.detailPage, .pill, .topOfList, .sidebar]
            ) == .topOfList
        )
        // And without anything pending, the button belongs to tvOS.
        #expect(FocusRules.stepOut(along: FocusRules.vodLadder, pending: []) == nil)
    }

    /// **Whoever is already at the top has this step behind them.** Otherwise one would be stuck
    /// at the start of the list: a press that does nothing looks on the TV like a broken button.
    @Test("The start of the list is pending only if one is not standing there")
    func topOfListPendsOnlyWhenBelow() {
        let ids = ["a", "b", "c"]

        #expect(LibraryView.pendingExitSteps(focus: "c", ids: ids).contains(.topOfList))
        #expect(!LibraryView.pendingExitSteps(focus: "a", ids: ids).contains(.topOfList))
        // On the buttons above the grid or on a jump marker: Whoever is not in the grid at all is
        // not first put back into it.
        #expect(!LibraryView.pendingExitSteps(focus: "cat-open", ids: ids).contains(.topOfList))
        #expect(!LibraryView.pendingExitSteps(focus: "jump-B", ids: ids).contains(.topOfList))
        #expect(!LibraryView.pendingExitSteps(focus: nil, ids: ids).contains(.topOfList))
        // And without content there is nothing to jump to.
        #expect(!LibraryView.pendingExitSteps(focus: "a", ids: []).contains(.topOfList))
    }

    /// The sidebar is the end of **this** staircase and not of the path — from there
    /// ``AppSidebar/Destination/stepOut`` continues.
    @Test("The bar is always pending")
    func sidebarAlwaysPends() {
        #expect(LibraryView.pendingExitSteps(focus: nil, ids: []).contains(.sidebar))
        #expect(LibraryView.pendingExitSteps(focus: "a", ids: ["a"]).contains(.sidebar))
    }

    /// **The whole path as the viewer described it** (2026-08-11): to the start of the list, into
    /// the sidebar onto "Filme & Serien", on to "Mediathek", and only the fourth press closes
    /// the app.
    @Test("Four presses from the provider library, only then out")
    func vodTakesFourPresses() {
        var presses = 0

        // 1st step: to the start of the list.
        #expect(
            FocusRules.stepOut(
                along: FocusRules.vodLadder,
                pending: LibraryView.pendingExitSteps(focus: "z", ids: ["a", "z"])
            ) == .topOfList
        )
        presses += 1

        // 2nd step: into the sidebar, onto the entry of the open section.
        #expect(
            FocusRules.stepOut(
                along: FocusRules.vodLadder,
                pending: LibraryView.pendingExitSteps(focus: "a", ids: ["a", "z"])
            ) == .sidebar
        )
        presses += 1
        var entry = AppSidebar.mainEntry(for: .vodProvider("liste"))
        #expect(entry == .vod)

        // 3rd step: on to "Mediathek".
        entry = entry.stepOut ?? entry
        presses += 1
        #expect(entry == .media)

        // 4th press: there the button belongs to tvOS.
        #expect(entry.stepOut == nil)
        presses += 1
        #expect(presses == 4)
    }

    // MARK: - Wrap-around in the bar

    /// **tvOS has no natural wraparound.** Whoever is at the bottom at the settings and keeps
    /// pressing stays put — and keeps pressing until they take the app for stuck.
    @Test("Arriving at the bottom the bar jumps to the top")
    func sidebarWrapsAtTheBottom() {
        let rows: [AppSidebar.Destination] = [.media, .search, .favorites, .settings]

        #expect(AppSidebar.wrapped(from: .settings, by: 1, in: rows) == .media)
        #expect(AppSidebar.wrapped(from: .media, by: -1, in: rows) == .settings)

        // **Nothing may happen in the middle of the sidebar.** `onMoveCommand` arrives even when
        // the focus has already moved — whoever also moves on here jumps two rows on one press
        // (viewer finding 2026-08-11).
        #expect(AppSidebar.wrapped(from: .search, by: 1, in: rows) == nil)
        #expect(AppSidebar.wrapped(from: .favorites, by: -1, in: rows) == nil)
        // And at the edge only in the direction in which it does not continue.
        #expect(AppSidebar.wrapped(from: .media, by: 1, in: rows) == nil)
        #expect(AppSidebar.wrapped(from: .settings, by: -1, in: rows) == nil)
    }

    // MARK: - Wrap-around in the settings

    /// The same promise as in the sidebar, and for the same reason (requirement 2026-08-11: at the
    /// very top, pressing up should come out at the bottom, and vice versa).
    @Test("The settings section list wraps around at both edges")
    func settingsWrapAtBothEnds() {
        let first = SettingsSection.allCases.first
        let last = SettingsSection.allCases.last

        #expect(SettingsSection.wrapped(from: last, by: 1) == first)
        #expect(SettingsSection.wrapped(from: first, by: -1) == last)

        // In the middle of the list the focus itself moves — otherwise it jumps twice per press.
        #expect(SettingsSection.wrapped(from: .playback, by: 1) == nil)
        #expect(SettingsSection.wrapped(from: .playback, by: -1) == nil)
        // And at the edge only in the direction in which it does not continue.
        #expect(SettingsSection.wrapped(from: first, by: 1) == nil)
        #expect(SettingsSection.wrapped(from: last, by: -1) == nil)
        // Without a section — the focus is on a catcher — nothing happens.
        #expect(SettingsSection.wrapped(from: nil, by: 1) == nil)
    }

    @Test("The settings focus mark names its section")
    func settingsFocusNamesItsSection() {
        #expect(SettingsView.section(ofFocus: "section-playback") == .playback)
        // The two catchers are not sections — if they acted like it, the display would follow the
        // geometry on entry instead of the choice.
        #expect(SettingsView.section(ofFocus: SettingsView.listEntryID) == nil)
        #expect(SettingsView.section(ofFocus: SettingsView.listReturnID) == nil)
        #expect(SettingsView.section(ofFocus: nil) == nil)
    }

    @Test("Where there is nothing to wrap around, nothing happens")
    func sidebarNothingToWrap() {
        #expect(AppSidebar.wrapped(from: .media, by: 1, in: [.media]) == nil)
        #expect(AppSidebar.wrapped(from: nil, by: 1, in: [.media, .search]) == nil)
        // An entry that does not exist at the moment — the sync, say, while a list is expanded —
        // is not a starting point.
        #expect(AppSidebar.wrapped(from: .sync, by: 1, in: [.media, .search]) == nil)
    }

    // MARK: - The season you are in

    static func season(_ number: Int, unplayed: Int?) -> MediaItem {
        MediaItem(
            id: "s\(number)", kind: .season, title: "Staffel \(number)",
            seasonNumber: number, unplayedCount: unplayed
        )
    }

    /// **The case "The Ember Lab".** Whoever is at season 6 should open there — until now
    /// it was always season 1, and the way there started from the beginning every time.
    @Test("It opens on the first season with unwatched episodes")
    func opensAtTheRunningSeason() {
        let seasons = [
            Self.season(1, unplayed: 0), Self.season(2, unplayed: 0),
            Self.season(3, unplayed: 0), Self.season(4, unplayed: 0),
            Self.season(5, unplayed: 0), Self.season(6, unplayed: 12),
            Self.season(7, unplayed: 24),
        ]
        #expect(DetailModel.startingSeason(in: seasons)?.seasonNumber == 6)
    }

    /// Whoever has finished a series looks for the newest episode and not the oldest.
    @Test("If everything is watched, it is the last season")
    func finishedSeriesOpensAtTheLast() {
        let seasons = [
            Self.season(1, unplayed: 0), Self.season(2, unplayed: 0),
            Self.season(3, unplayed: 0),
        ]
        #expect(DetailModel.startingSeason(in: seasons)?.seasonNumber == 3)
    }

    /// **Without information nothing is claimed.** "Everything watched" and "the server did not
    /// count" look the same at this point; they must not be treated the same, otherwise a fresh
    /// series opens at the last season.
    @Test("Without a count it stays on the first season")
    func withoutCountsItStaysAtTheFirst() {
        let seasons = [
            Self.season(1, unplayed: nil), Self.season(2, unplayed: nil),
        ]
        #expect(DetailModel.startingSeason(in: seasons)?.seasonNumber == 1)
    }

    @Test("Without seasons there is nothing to choose")
    func noSeasons() {
        #expect(DetailModel.startingSeason(in: []) == nil)
    }

    // MARK: - Entering the season row

    /// **The relapse of 2026-08-11, and the finding is more precise than the first time:** Not just
    /// any wrong season, but **always the second** — the one that lies geometrically below the
    /// play button. Two requests to tvOS were not enough; what is corrected now is the focus
    /// change itself.
    @Test("From the button row down it goes to the current season")
    func enteringFromTheButtonsCorrectsTheSeason() {
        #expect(
            DetailView.seasonOnEntry(previous: "play", current: "season-s2", selected: "s6")
                == "season-s6"
        )
        // Also from the episodes upward and from outside the page.
        #expect(
            DetailView.seasonOnEntry(previous: "ep-17", current: "season-s2", selected: "s6")
                == "season-s6"
        )
        #expect(
            DetailView.seasonOnEntry(previous: nil, current: "season-s2", selected: "s6")
                == "season-s6"
        )
    }

    /// **Whoever wanders in the row has chosen.** If the correction applied here too, one would
    /// never get out of the current season — every step to the side would jump back.
    @Test("Within the row nothing is corrected")
    func movingWithinTheRowIsAChoice() {
        #expect(
            DetailView.seasonOnEntry(previous: "season-s6", current: "season-s7", selected: "s6")
                == nil
        )
    }

    /// A second assignment to the same identifier would be a focus change without movement — and
    /// the follow-up would run into a loop.
    @Test("Whoever already stands correctly is not set again")
    func alreadyCorrectStaysPut() {
        #expect(
            DetailView.seasonOnEntry(previous: "play", current: "season-s6", selected: "s6") == nil
        )
    }

    // MARK: - Entering the episode row

    /// **The same sickness one row deeper** (user finding 2026-08-12): Hollowmark has over 300 episodes
    /// in season 1 — otherwise you have to press forward forever. Whoever comes down from the
    /// season landed on episode 1 because it is on the left.
    @Test("From the season down it goes to the resume episode")
    func enteringTheEpisodeRowFindsTheResumePoint() {
        let episodes = ["f1", "f54", "f55", "f56"]

        #expect(
            DetailView.episodeOnEntry(
                previous: "season-s1", current: "f1", episodes: episodes, resuming: "f55",
                remembered: nil
            ) == "f55"
        )
    }

    @Test("Within the episodes nothing is corrected")
    func movingWithinTheEpisodeRowIsAChoice() {
        let episodes = ["f1", "f54", "f55", "f56"]

        #expect(
            DetailView.episodeOnEntry(
                previous: "f55", current: "f56", episodes: episodes, resuming: "f55", remembered: nil
            ) == nil
        )
    }

    /// **Without a resume point it stays with the allocation.** A season nobody has started has
    /// no episode "where one was" — then the first is the right answer and not a guessed one.
    @Test("Without a resume episode nothing happens")
    func withoutAResumePointNothingHappens() {
        let episodes = ["f1", "f2"]

        #expect(
            DetailView.episodeOnEntry(
                previous: "season-s1", current: "f1", episodes: episodes, resuming: nil, remembered: nil
            ) == nil
        )
        // And a resume episode from another season does not count here: The row shows the episodes
        // of the chosen season, and a focus on something that is not there fizzles.
        #expect(
            DetailView.episodeOnEntry(
                previous: "season-s1", current: "f1", episodes: episodes, resuming: "fremd",
                remembered: nil
            ) == nil
        )
        // Whoever is already in the right place is not set again.
        #expect(
            DetailView.episodeOnEntry(
                previous: "season-s1", current: "f2", episodes: episodes, resuming: "f2", remembered: nil
            ) == nil
        )
    }

    // MARK: - The return from playback

    /// **The finding itself, with its numbers** (device 2026-08-24): 62 episodes paged through, one
    /// watched, menu button — and the page was back on the resume episode. The player lies as a
    /// full screen over the detail page; on return `previous` is therefore `nil` as with every
    /// entry from outside, and the return cannot be recognized from it alone.
    @Test("The return from the player lands on the remembered episode")
    func returningFromPlaybackKeepsThePlace() {
        let episodes = (1...62).map { "f\($0)" }

        #expect(
            DetailView.episodeOnEntry(
                previous: nil, current: "f1", episodes: episodes, resuming: "f7",
                remembered: "f62"
            ) == "f62"
        )
    }

    /// Without a remembered position everything stays as it was — and a remembered episode from
    /// another season is not in this list. That is at the same time the entire invalidation on a
    /// season change: no deleting needed alongside.
    @Test("Without a remembered episode it stays on the resume episode")
    func withoutARememberedEpisodeTheResumePointWins() {
        let episodes = ["f1", "f7", "f62"]

        #expect(
            DetailView.episodeOnEntry(
                previous: nil, current: "f1", episodes: episodes, resuming: "f7", remembered: nil
            ) == "f7"
        )
        #expect(
            DetailView.episodeOnEntry(
                previous: nil, current: "f1", episodes: episodes, resuming: "f7",
                remembered: "fremd"
            ) == "f7"
        )
    }

    /// Otherwise ``DetailView/jumpToEpisode(_:)`` would set the focus on itself and drive the
    /// follow-up into the loop the rule warns about.
    @Test("If the focus is already on the remembered episode, nothing happens")
    func alreadyOnTheRememberedEpisodeStaysPut() {
        #expect(
            DetailView.episodeOnEntry(
                previous: nil, current: "f62", episodes: ["f1", "f62"], resuming: "f1",
                remembered: "f62"
            ) == nil
        )
    }

    /// **One answer for all ways in.** If the ranking stood at each place individually, the
    /// pre-highlight would point at one episode and the entry at the other — and the wrong card
    /// would light up for a frame.
    @Test("Entry has an answer for every way in")
    func theEntryTargetIsOneAnswer() {
        let episodes = ["f1", "f7", "f62"]

        #expect(
            DetailView.episodeEntry(episodes: episodes, resuming: "f7", remembered: "f62") == "f62"
        )
        #expect(DetailView.episodeEntry(episodes: episodes, resuming: "f7", remembered: nil) == "f7")
        #expect(DetailView.episodeEntry(episodes: episodes, resuming: nil, remembered: nil) == nil)
        // No guessing: If the resume episode is not in the list, the answer is none — and not the
        // first episode.
        #expect(
            DetailView.episodeEntry(episodes: episodes, resuming: "fremd", remembered: nil) == nil
        )
    }

    // MARK: - The follow-ups

    /// **The own trigger must not abort the follow-up.** It starts from the focus change, and
    /// the associated key press arrives only afterwards — measured three milliseconds later
    /// (focus trace 2026-08-12). Without the tolerance every follow-up would abort on exactly the
    /// press it is running for.
    @Test("The own trigger does not cancel the follow-up")
    func theOwnCauseDoesNotAbandonTheRetry() {
        let start = Date()

        #expect(!FocusRules.abandonsRetry(startedAt: start, lastInput: start))
        #expect(!FocusRules.abandonsRetry(startedAt: start, lastInput: start.addingTimeInterval(0.003)))
        // A press from earlier is not one from now.
        #expect(!FocusRules.abandonsRetry(startedAt: start, lastInput: .distantPast))
    }

    /// And it must apply already **before** the first pass: That one is at 50 ms, and an abort
    /// afterwards would already have reset the viewer's movement once.
    @Test("A press during the follow-up cancels it")
    func anInputDuringTheRetryAbandonsIt() {
        let start = Date()

        #expect(FocusRules.abandonsRetry(startedAt: start, lastInput: start.addingTimeInterval(0.03)))
        #expect(FocusRules.abandonsRetry(startedAt: start, lastInput: start.addingTimeInterval(0.24)))
    }

    @Test("Outside the season row nothing happens")
    func outsideTheRowNothingHappens() {
        #expect(DetailView.seasonOnEntry(previous: "play", current: "ep-3", selected: "s6") == nil)
        #expect(DetailView.seasonOnEntry(previous: "play", current: nil, selected: "s6") == nil)
        // Without a chosen season there is nothing to correct — then the page is still in the
        // loading state.
        #expect(
            DetailView.seasonOnEntry(previous: "play", current: "season-s2", selected: nil) == nil
        )
    }

    // MARK: - Entering the sidebar

    /// **Arrival is on the entry of the open section**, not where the geometry points. Whoever
    /// is in a Live group and goes left should land on "Live".
    @Test("The entry point hits the entry of the open section")
    func entryPointFollowsTheOpenSection() {
        #expect(AppSidebar.mainEntry(for: .liveGroup("TR · Genel")) == .live)
        #expect(AppSidebar.mainEntry(for: .liveProvider("A")) == .live)
        #expect(
            AppSidebar.mainEntry(for: .liveProviderGroup(provider: "A", group: "News")) == .live)
        #expect(AppSidebar.mainEntry(for: .vodProvider("liste")) == .vod)
        #expect(AppSidebar.mainEntry(for: .media) == .media)
        // The sync is not a target — it lives under "Mediathek".
        #expect(AppSidebar.mainEntry(for: .sync) == .media)
    }
}

/// **Left and right switch the filmography tab** (test report 2026-08-08).
///
/// Whoever is in the list and wants to go to the series first had to go up to the tabs, there
/// sideways and down again — three ways for a switch that the remote does in one press.
@Suite("Filmography · tabs")
/// On the main actor, because the rules being checked live there (AP15, 2026-09-02): The warning
/// gate turns "nonisolated calls MainActor" into a failure — and that is what it always was
/// in substance.
@MainActor
struct FilmographyTabRuleTests {

    @Test("Sideways leads into the other tab")
    func sidewaysSwitches() {
        #expect(FilmographySheet.tab(from: .movies, moving: .right) == .series)
        #expect(FilmographySheet.tab(from: .series, moving: .left) == .movies)
    }

    /// **Without wraparound**, unlike sidebar and channel list: Two tabs, and whoever is on the
    /// right and keeps pressing right does not mean "start again from the front" — they mean
    /// nothing at all, and then staying put is the answer.
    @Test("At the edge nothing happens")
    func edgesDoNothing() {
        #expect(FilmographySheet.tab(from: .series, moving: .right) == nil)
        #expect(FilmographySheet.tab(from: .movies, moving: .left) == nil)
    }

    @Test("Up and down belong to the list")
    func verticalBelongsToTheList() {
        // Otherwise the tabs would switch while paging through the rows.
        #expect(FilmographySheet.tab(from: .movies, moving: .up) == nil)
        #expect(FilmographySheet.tab(from: .movies, moving: .down) == nil)
    }

    /// **The tab switch must never drop the focus** (K8).
    ///
    /// On tvOS focus `nil` means: no more move commands, and the menu button goes to the system
    /// — the case documented in ``MainView``, "The app closed". The empty tab is not an edge
    /// case here but the normal case for a name with only one kind.
    ///
    /// **`@MainActor` is load-bearing here, not decoration.** ``FilmographySheet`` is a `View`
    /// and therefore bound to the main actor — its static calculations too. Without the binding
    /// the call compiles but falls into the isolation check at runtime and takes the **whole**
    /// check run down (signal 5, without a single red line: the message names only the process,
    /// not the case). Happened exactly like that on 2026-08-27.
    @MainActor
    @Test("The tab switch never sets the focus to nothing")
    func focusAfterTabChangeNeverClearsFocus() {
        #expect(FilmographySheet.focusAfterTabChange(firstEntryID: "tt42") == "entry-tt42")
        // No entry: the stop catches the focus instead of letting it drop.
        #expect(FilmographySheet.focusAfterTabChange(firstEntryID: nil) == FilmographySheet.anchorID)
    }
}

/// The edge press of the wraparound — and its straggler.
///
/// **The numeric finding of 2026-08-16:** Seven entries, every sixth press a double; eight
/// entries, every seventh — it was exactly the press that LANDS on the last entry that
/// doubled. `onMoveCommand` reports only after the native focus step; this straggler must not
/// schedule a wraparound.
@Suite("Wrap-around · the real edge press")
/// On the main actor, because the rules being checked live there (AP15, 2026-09-02): The warning
/// gate turns "nonisolated calls MainActor" into a failure — and that is what it always was
/// in substance.
@MainActor
struct EdgePressRuleTests {

    @Test("The straggler of a used-up press schedules no wrap-around")
    func latecomerIsNoEdgePress() {
        let moved = Date()
        // Measured, the command arrived 4–180 ms after the focus step.
        #expect(!AppSidebar.isEdgePress(lastFocusMove: moved, now: moved.addingTimeInterval(0.004)))
        #expect(!AppSidebar.isEdgePress(lastFocusMove: moved, now: moved.addingTimeInterval(0.18)))
    }

    @Test("A press on a resting focus is a real edge press")
    func restingFocusMeansEdgePress() {
        let moved = Date()
        #expect(AppSidebar.isEdgePress(lastFocusMove: moved, now: moved.addingTimeInterval(0.3)))
        #expect(AppSidebar.isEdgePress(lastFocusMove: .distantPast, now: moved))
    }

    /// **The wait must not grow again.**
    ///
    /// It once stood at 320 ms — and the wraparound thereby needed 359 ms going up and 662 ms
    /// going down, where an ordinary step costs 76 to 150 ms (focus trace 2026-08-22). That was
    /// exactly the "doesn't feel smooth". This limit holds the value below the ordinary step:
    /// Whoever raises it again has to get past here first.
    @Test("The wrap-around waits shorter than an ordinary step takes")
    func wrapDelayStaysBelowANormalStep() {
        #expect(AppSidebar.wrapDelay <= 80)
        // And not zero: The safeguard `focus == on` needs a moment in which a late movement from
        // tvOS could still be noticed.
        #expect(AppSidebar.wrapDelay > 0)
    }

    /// The edge-press test must keep catching the straggler — it is what permits the short wait
    /// at all.
    @Test("The straggler stays filtered even with a short wait")
    func latecomerFilterOutlivesTheShortWait() {
        #expect(AppSidebar.consumedPressWindow > Double(AppSidebar.wrapDelay) / 1000)
    }
}
