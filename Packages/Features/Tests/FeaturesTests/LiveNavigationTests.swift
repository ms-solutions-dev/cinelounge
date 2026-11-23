import Core
import Foundation
import Testing

@testable import Features

/// The rules from the on-device test of 2026-08-11 — Live operation, second round.
///
/// **What stands here is the part that can be answered without a TV.** The
/// test report opened three points, all asking the same question: who
/// gets the keypress. Rules about values can be pinned down; whether tvOS
/// lets the press through to them is decided on the device — and exactly
/// for that reason the wraparound now no longer hangs on `onMoveCommand`, but on
/// focusable edge rows.
@Suite("Live controls, second round")
/// On the main actor, because the rules being checked live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct LiveNavigationTests {

    // MARK: - The overlay timeout

    /// **Longer than the control bar, and that is the subject under test.** The
    /// bar is glanced at, the overlay is read — someone checking
    /// the guide for what is on at half past eight presses no key for minutes.
    @Test("The overlay stays longer than the control bar")
    @MainActor
    func overlayOutlivesTheBar() {
        #expect(PlayerScreen.overlayTimeout > PlayerModel.barTimeout)
    }

    @Test("Without input it closes")
    func closesWhenIdle() {
        let opened = Date(timeIntervalSince1970: 1_000_000)
        let later = opened.addingTimeInterval(PlayerScreen.overlayTimeout + 1)
        #expect(PlayerScreen.shouldCloseOverlay(touchedAt: opened, now: later))
    }

    @Test("Every movement resets the timeout")
    func stillOpenWhileSomebodyIsThere() {
        let touched = Date(timeIntervalSince1970: 1_000_000)
        let soon = touched.addingTimeInterval(PlayerScreen.overlayTimeout - 1)
        #expect(!PlayerScreen.shouldCloseOverlay(touchedAt: touched, now: soon))
    }

    // MARK: - The way sideways in the Live section

    /// **Two attempts failed here, and both on the same assumption.**
    /// First an invisible strip on the left was supposed to catch the press, then a
    /// button. Both assumed that tvOS moves focus to the left at all —
    /// reproduced in the simulator it does **not**: focus stays
    /// where it is. The press is thus unconsumed, and exactly then
    /// it arrives as `onMoveCommand`. The rule therefore stands here and not in
    /// the focus guidance.
    @Test("From the channel list to the left: the groups")
    func leftFromTheChannelListOpensGroups() {
        #expect(LiveView.sideStep(.left, showsGroups: false) == .showGroups)
    }

    @Test("From the groups to the right: back to the channels")
    func rightFromTheGroupsGoesBack() {
        #expect(LiveView.sideStep(.right, showsGroups: true) == .backToChannels)
    }

    /// **Focus is set and not moved.** The sidebar keeps its
    /// own focus state; there is no geometric path to it.
    @Test("From the groups to the left: into the sidebar")
    func leftFromTheGroupsLeaves() {
        #expect(LiveView.sideStep(.left, showsGroups: true) == .toSidebar)
    }

    /// Moving right out of the channel list belongs to the board — there are
    /// "Play" and "Add to favorites", and focus reaches those by itself.
    @Test("Right from the channel list is left to the focus guide")
    func rightFromTheChannelListIsNotOurs() {
        #expect(LiveView.sideStep(.right, showsGroups: false) == .none)
        #expect(LiveView.sideStep(.up, showsGroups: false) == .none)
        #expect(LiveView.sideStep(.down, showsGroups: true) == .none)
    }

    // MARK: - Edge rows as wrap-around

    /// **The edge rows must not coincide with any channel ID.** They
    /// are in the same focus state as the rows; an overlap would mean
    /// that a channel triggers the wraparound.
    @Test("The edge rows carry their own identifiers")
    func edgeIDsAreDistinct() {
        #expect(LiveOverlay.topEdgeID != LiveOverlay.bottomEdgeID)
        #expect(LiveOverlay.topEdgeID.hasPrefix("-"))
        #expect(LiveOverlay.bottomEdgeID.hasPrefix("-"))
        #expect(!LiveOverlay.topEdgeID.hasPrefix(LiveOverlay.groupPrefix))
        #expect(!LiveOverlay.bottomEdgeID.hasPrefix(LiveOverlay.groupPrefix))
    }

    // MARK: - Entering "Live"

    /// **The sound nobody ordered** (viewer finding 2026-09-02: when the preview area is off but the
    /// preview video is on, opening with
    /// "Live" jumps straight to the last watched channel — but in the background the
    /// video from the Live preview plays alongside).
    ///
    /// The cause lies in the order: the "jumped" flag is
    /// set **after** the jump has taken place. On the next
    /// redraw the answer was thus "do not jump" — and the view
    /// built the overview area, under the player, where nobody
    /// sees it. It loaded the catalog, set focus and after four
    /// seconds started the preview of the first channel: a second stream at a
    /// provider that allows one.
    @Test("While the jumped-to channel is playing, the section is not built")
    func noBrowseAreaBehindThePlayer() {
        #expect(
            MainView.jumpsDirectly(
                failed: false, jumped: true, isPlaying: true, overview: false,
                remembered: true))
    }

    /// Whoever leaves the player gets the area — that is the way back,
    /// and without it the jump would catch one straight away.
    @Test("After the player the section is back")
    func browseAreaAfterThePlayer() {
        #expect(
            !MainView.jumpsDirectly(
                failed: false, jumped: true, isPlaying: false, overview: false,
                remembered: true))
    }

    @Test("Without an overview section Live leads to the remembered channel")
    func jumpsWithoutTheBrowseArea() {
        #expect(
            MainView.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: false,
                remembered: true))
    }

    /// Three cases lead into the area, and all three on purpose: the
    /// switch is on, there is no remembered channel (first start), or
    /// the jump led nowhere.
    @Test("Switch, empty memory and a failed jump lead into the section")
    func staysInTheBrowseArea() {
        #expect(
            !MainView.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: true,
                remembered: true))
        #expect(
            !MainView.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false, overview: false,
                remembered: false))
        #expect(
            !MainView.jumpsDirectly(
                failed: true, jumped: false, isPlaying: true, overview: false,
                remembered: true))
    }

    /// **Only for the jump case.** If the overview area is switched on,
    /// it stays, even while playing: it gave up its preview itself
    /// on opening, and tearing it down under the player
    /// would cost scroll position, focus and group.
    @Test("The switched-on overview section stays during playback too")
    func theBrowseAreaSurvivesPlayback() {
        #expect(
            !MainView.jumpsDirectly(
                failed: false, jumped: false, isPlaying: true, overview: true,
                remembered: true))
    }

    // MARK: - The catcher over the image surface (AP4 · K2)

    /// **The pressed button vanished under the thumb.** `togglePause()`
    /// brings up the bar, and with that the play button took the place of the
    /// catcher: whoever thought the first press had no effect and pressed again
    /// operated a different control than the first time.
    @Test("After a press on the surface the catcher stays")
    @MainActor
    func starterStaysPut() {
        #expect(PlayerScreen.showsCatcher(barVisible: true, isPanelOpen: false, isHolding: true))
    }

    /// Without a hold the old rule applies: if the bar is up, focus belongs to it.
    @Test("Without a hold the standing bar belongs to itself")
    @MainActor
    func withoutStopTheBarOwnsItself() {
        #expect(!PlayerScreen.showsCatcher(barVisible: true, isPanelOpen: false, isHolding: false))
        #expect(PlayerScreen.showsCatcher(barVisible: false, isPanelOpen: false, isHolding: false))
    }

    /// **An open window beats both.** Otherwise the invisible
    /// catcher would lie over the track selection and swallow the selection press — the same
    /// bug the filmography had on 2026-08-16.
    @Test("An open window beats the catcher")
    @MainActor
    func openWindowBeatsEverything() {
        #expect(!PlayerScreen.showsCatcher(barVisible: false, isPanelOpen: true, isHolding: true))
    }
}
