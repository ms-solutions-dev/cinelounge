import Core
import CoreGraphics
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import Features

/// Bar, panels, hints, space and screensaver — the UI of the player.
extension PlayerModelTests {

    // MARK: - Buffering and errors

    @Test("While buffering, playback counts as running")
    func bufferingCountsAsPlaying() async {
        // The button shows ``PlayerModel/isPlaying`` and not `.playing`. From the
        // direct comparison the play icon jumped into view when playback stuttered,
        // and the same press called `play()` on a running engine instead of `pause()` —
        // the viewer could not pause exactly when the picture is frozen.
        let (model, host, _) = make()
        host.engine.status = .buffering
        await model.tick()

        #expect(model.isPlaying)
        #expect(model.isBuffering, "and the reason for the stalled picture stays named")

        model.togglePause()
        #expect(host.engine.didPause, "the press pauses instead of starting again")
    }

    @Test("While buffering, the bar comes back by itself")
    func bufferingBringsBackTheBar() async {
        // Without the bar there is no place where "Buffering" could stand. It
        // hides after four seconds — exactly the state in which a movie
        // over a thin line starts to stutter. The viewer would see a
        // frozen picture without any indication and take it for a crash.
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()
        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(!model.isBarVisible)

        host.engine.status = .buffering
        await model.tick()

        #expect(model.isBarVisible)
        // And it stays: it is hidden only while the picture is running.
        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(model.isBarVisible)
    }

    @Test("An open panel covers the bar instead of letting it show through")
    func openPanelHidesTheBar() {
        // The gradient of the info area is only 86% opaque at the top. As long as the
        // bar was drawn underneath, title line, track and
        // button row shone through as ghost text between the cast names.
        // ``PlayerModel/isBarVisible`` deliberately stays set — after
        // closing, the bar should be there again without anyone having to
        // bring it up first. Only the drawing is covered.
        let (model, _, _) = make()
        #expect(model.showsBar)

        model.isInfoVisible = true
        #expect(!model.showsBar)
        #expect(model.isBarVisible, "the state stays, it just is not drawn")

        model.isInfoVisible = false
        #expect(model.showsBar, "after closing, the bar is back")

        model.isChoosingTracks = true
        #expect(!model.showsBar, "the same applies to the track picker")
    }

    @Test("A failed engine shows a notice instead of closing silently")
    func failureShowsNoticeAndStaysOpen() async {
        // Until now only the progress counter signed off: title and bar stood
        // over black at 00:00, with no reason and no hint that the menu button
        // helps. Closing by itself would be no solution — it cannot be told apart from a
        // swallowed keypress, and the viewer starts
        // the same title again right away.
        let (model, host, source) = make()
        host.engine.status = .playing
        await model.tick()
        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(!model.isBarVisible)

        host.engine.status = .failed
        await model.tick()

        #expect(model.hasFailed)
        #expect(model.isBarVisible, "the notice needs the bar that carries it")
        #expect(!model.shouldClose, "it closes only on request")
        // The session on the server is signed off anyway, otherwise it stands there
        // for hours as playing.
        #expect(source.ended.count == 1)

        // And the way out is ready.
        model.close()
        #expect(model.shouldClose)
    }

    // MARK: - Tracks

    @Test("Tracks that appear only later arrive in the selection")
    func lateTracksArrive() async {
        // VLC determines the tracks only while playback is starting up. Whoever asks
        // once and keeps the result shows "no tracks" for the whole movie —
        // and the audio track cannot be switched.
        let (model, host, _) = make()
        host.engine.status = .opening
        await model.tick()
        #expect(model.audioTracks.isEmpty)

        host.engine.status = .playing
        host.engine.audioTracks = [
            PlaybackTrack(id: 0, rawName: "Track 1", language: "deu"),
            PlaybackTrack(id: 1, rawName: "Commentary", language: "eng"),
        ]
        await model.tick()

        #expect(model.audioTracks.count == 2)
        #expect(model.audioTracks[0].displayName(locale: Locale(identifier: "de")) == "Deutsch")
    }

    @Test("Choosing a track goes to the engine and shows in the display immediately")
    func trackSelectionReachesEngine() async {
        // The engine reports the selection back only on the next tick. Until then the
        // checkmark would be on the old track, and it would look as if the press had done
        // nothing.
        let (model, host, _) = make()

        model.selectSubtitleTrack(3)

        #expect(host.engine.selectedSubtitleTrack == 3)
        #expect(model.selectedSubtitleTrack == 3)
    }

    // MARK: - Info section

    @Test("An aborted cast query is repeated the next time it opens")
    func infoLoadRetriesAfterFailure() async {
        // The query hangs on a `task` of the info area, and it is cancelled as soon as
        // the area closes again. Whoever sets the flag before the answer locks out
        // an attempt without a result: the area then shows a spinner for the whole movie,
        // and cast and episodes never come. From here the cancellation looks
        // like a failure — that is why it is reproduced that way.
        let (model, _, source) = make()
        source.itemToReturn = nil

        await model.loadInfoIfNeeded()
        #expect(model.cast.isEmpty)

        source.itemToReturn = MediaItem(
            id: "film",
            kind: .movie,
            title: "Zirkel der Uhrmacher",
            cast: [Person(id: "p1", name: "Konrad L. Wester", role: .actor)]
        )
        await model.loadInfoIfNeeded()

        #expect(model.cast.count == 1)

        // And after that only once: two queries per opening are clearly felt on a narrow
        // line.
        source.itemToReturn = MediaItem(id: "film", kind: .movie, title: "Andere Antwort")
        await model.loadInfoIfNeeded()
        #expect(model.cast.count == 1)
    }

    // MARK: - Bar

    @Test("The bar fades out after a few seconds without input")
    func barHidesWhenIdle() {
        // The template shows a movie without any controls. A bar that stays up
        // permanently covers the bottom quarter of the picture.
        let shown = Date()
        let later = shown.addingTimeInterval(PlayerModel.barTimeout + 0.5)

        #expect(PlayerModel.shouldHideBar(shownAt: shown, now: later, status: .playing))
        #expect(!PlayerModel.shouldHideBar(shownAt: shown, now: shown, status: .playing))
    }

    @Test("While the picture is stalled, the bar stays visible")
    func barStaysWhilePaused() {
        // A frozen picture without any indication looks like a crash, and
        // nobody knows whether the remote still does anything.
        let shown = Date()
        let later = shown.addingTimeInterval(60)

        #expect(!PlayerModel.shouldHideBar(shownAt: shown, now: later, status: .paused))
        #expect(!PlayerModel.shouldHideBar(shownAt: shown, now: later, status: .buffering))
    }

    @Test("Any input brings the bar back")
    func interactionShowsBar() async {
        let (model, host, _) = make()
        host.engine.status = .playing
        // First one tick: before it the model still stands at `opening`, and with a frozen
        // picture the bar deliberately does not hide.
        await model.tick()

        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(!model.isBarVisible)

        model.noteInteraction()
        #expect(model.isBarVisible)
    }

    @Test("With the info area open, the bar does not vanish under the focus")
    func openPanelKeepsBar() async {
        // If the bar disappears while focus sits on it, focus jumps into
        // nothing, and tvOS puts it at an arbitrary place.
        let (model, host, _) = make()
        host.engine.status = .playing
        await model.tick()
        model.isInfoVisible = true

        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))

        #expect(model.isBarVisible)

        // Without an open area the same deadline hides it — otherwise the case would check
        // nothing, because the bar would have stayed up anyway.
        model.isInfoVisible = false
        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(!model.isBarVisible)
    }

    // MARK: - Accelerated seeking

    /// **The ladder, recalculated.**
    ///
    /// The occasion (viewer finding 2026-08-28: when fast-forwarding through a two-to-three-hour
    /// movie, the user otherwise has to press around forever). With a fixed 30 seconds,
    /// an hour costs 120 keypresses.
    @Test(
        "The acceleration steps are fixed",
        arguments: [
            (1, 30.0), (4, 30.0),
            (5, 60.0), (8, 60.0),
            (9, 120.0), (12, 120.0),
            (13, 300.0), (99, 300.0),
        ])
    func scrubLadder(_ scenario: (Int, TimeInterval)) {
        #expect(PlayerModel.scrubStep(at: scenario.0) == scenario.1)
    }

    @Test("Holding makes seeking faster")
    func heldGetsFaster() async {
        // Three hours, so that the ladder does not hit the end of the movie.
        let (model, host, _) = make(duration: 10800)
        host.engine.status = .playing
        host.engine.position = 0
        await model.tick()

        // Thirteen keypresses in a row, half a second apart — the
        // repeat rate of the remote.
        var now = Date()
        for _ in 1...13 {
            model.moveScrub(by: 1, now: now)
            now = now.addingTimeInterval(0.5)
        }

        // 4 × 30 + 4 × 60 + 4 × 120 + 1 × 300
        #expect(model.scrubPosition == 1140)
        // For comparison, what it was before: thirteen fixed steps of 30 s.
        #expect(model.scrubPosition! > 13 * PlayerModel.scrubStep)
    }

    @Test("A pause starts fine again")
    func pauseStartsFine() async {
        let (model, host, _) = make(duration: 10800)
        host.engine.status = .playing
        host.engine.position = 0
        await model.tick()

        var now = Date()
        for _ in 1...9 {
            model.moveScrub(by: 1, now: now)
            now = now.addingTimeInterval(0.5)
        }
        let afterHolding = model.scrubPosition!

        // Released, thought it over, tapped again.
        model.moveScrub(by: 1, now: now.addingTimeInterval(PlayerModel.scrubChain + 0.1))
        #expect(
            model.scrubPosition == afterHolding + 30,
            "whoever starts anew wants to aim precisely and not keep racing on")
    }

    @Test("A change of direction resets the chain")
    func directionChangeResets() async {
        let (model, host, _) = make(duration: 10800)
        host.engine.status = .playing
        host.engine.position = 5000
        await model.tick()

        var now = Date()
        for _ in 1...9 {
            model.moveScrub(by: 1, now: now)
            now = now.addingTimeInterval(0.5)
        }
        let forward = model.scrubPosition!

        model.moveScrub(by: -1, now: now)
        #expect(
            model.scrubPosition == forward - 30,
            "whoever reverses has overshot the target and wants to hit it")
    }

    @Test("After committing, the chain starts over")
    func adoptEndsTheChain() async {
        let (model, host, _) = make(duration: 10800)
        host.engine.status = .playing
        host.engine.position = 0
        await model.tick()

        var now = Date()
        for _ in 1...13 {
            model.moveScrub(by: 1, now: now)
            now = now.addingTimeInterval(0.5)
        }
        model.commitScrub()

        // Tapped once more right afterwards: without the reset one would
        // immediately be back at five-minute jumps.
        model.moveScrub(by: 1, now: now)
        let target = model.scrubPosition ?? 0
        #expect(target - model.position == 30)
    }

    @Test("An abandoned seek lapses with the bar")
    func hidingBarCancelsScrub() async {
        // The worst case in this area, because it stays silent: the tick takes over
        // the engine's position only when ``scrubPosition`` is empty. If it stays set
        // after the bar has disappeared, the movie keeps running while the
        // display, the next-episode offer and the resume point on the server
        // stay at the position that was never taken over. The bar itself cannot
        // clear it — it has disappeared together with its observer.
        let (model, host, _) = make(duration: 3600)
        host.engine.status = .playing
        host.engine.position = 100
        await model.tick()

        model.moveScrub(by: 4)
        #expect(model.scrubPosition == 220)

        model.hideBarIfIdle(now: .now.addingTimeInterval(PlayerModel.barTimeout + 1))
        #expect(!model.isBarVisible)
        #expect(model.scrubPosition == nil, "the bar takes the started seek with it")

        // And afterwards the tick runs along with the engine again.
        host.engine.position = 130
        await model.tick()
        #expect(model.position == 130)
        #expect(host.engine.seeks.isEmpty, "abandoned does not mean committed")
    }

    // MARK: - Rail

    @Test("The rail passes on what it does not need itself")
    func railPassesOnUnhandledMoves() {
        // `onMoveCommand` consumes **all** directions on the focused element —
        // an unhandled one arrives nowhere any more, and there is no return value
        // with which that could be reported. From a `default: break` it was impossible
        // to tell from outside whether the rail does not need a direction
        // or swallows it; ``TransportBar/RailMove/pass`` turns that into a value.
        // This check fails as soon as someone assigns a branch to `.up` again
        // without thinking about passing it on.
        #expect(TransportBar.railMove(.left) == .scrub(-1))
        #expect(TransportBar.railMove(.right) == .scrub(1))
        #expect(TransportBar.railMove(.down) == .toControls)
        #expect(TransportBar.railMove(.up) == .pass)
    }

    // MARK: - Screen space

    @Test("The controls stay within the overscan-safe area")
    func transportFitsScreen() {
        // Content that is too wide is centered by SwiftUI and runs out on **both** sides
        // without any warning. On the TV that looks like an edge bug and
        // is a space bug — recalculating is the only way to notice it.
        let screen: CGFloat = 1920
        let usable = screen - 2 * MetricsBoard.tv.margin

        let buttons = 4 * TransportBar.buttonSize + 3 * TransportBar.buttonGap
        #expect(buttons <= usable)

        // For the rail, clear space must remain between the two time labels,
        // otherwise the progress can no longer be read.
        let times = 2 * TransportBar.timeWidth + 2 * 22
        #expect(usable - times >= 800)

        #expect(TrackChooser.width + 2 * MetricsBoard.tv.margin <= screen)
        #expect(ScrubPreview.size.width < usable)

        // The two columns of the "Audio & Subtitles" index card side by side. They
        // stand in the info area inside the same overlay region; if too wide,
        // SwiftUI centers them, and then a track label is missing at both edges.
        #expect(2 * PlayerInfoPanel.columnWidth + PlayerInfoPanel.columnGap <= usable)

        // And the area itself must not cover the picture completely — it is supposed to show
        // that the movie keeps running.
        #expect(PlayerInfoPanel.height < 1080 - TVMetrics.topMargin)
    }

    @Test("The next-episode offer does not run into the button row")
    func nextUpDoesNotOverlapControls() {
        // Two focusable surfaces that overlap are a real problem on tvOS:
        // focus moves geometrically, and which of the two it hits is
        // unpredictable. The card is on the right, the buttons in the middle.
        let screen: CGFloat = 1920
        let buttons = 4 * TransportBar.buttonSize + 3 * TransportBar.buttonGap
        let buttonsRight = (screen + buttons) / 2
        let cardLeft = screen - MetricsBoard.tv.margin - NextUpOffer.cardWidth

        #expect(cardLeft > buttonsRight)
    }

    // MARK: - Second row

    @Test("An episode's second line names series, season and episode")
    func episodeSubtitle() {
        let episode = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            parentTitle: "Hollowmark",
            seasonNumber: 1,
            episodeNumber: 2
        )
        #expect(
            PlayerModel.episodeSubtitle(for: episode)
                == "Hollowmark · \(EpisodeIdentifier.text(season: 1, episode: 2))")

        // Without details better nothing than a separator with no content: a lone
        // "·" under the title looks like a bug.
        let bare = MediaItem(id: "x", kind: .movie, title: "Film")
        #expect(PlayerModel.episodeSubtitle(for: bare) == nil)
    }

    // MARK: - Screensaver

    @Test("The display is kept awake while playing, not on pause or at the end")
    func idleGuardRule() {
        #expect(PlayerModel.keepsDeviceAwake(.playing))
        #expect(PlayerModel.keepsDeviceAwake(.buffering))
        #expect(PlayerModel.keepsDeviceAwake(.opening))

        #expect(!PlayerModel.keepsDeviceAwake(.paused))
        #expect(!PlayerModel.keepsDeviceAwake(.idle))
        #expect(!PlayerModel.keepsDeviceAwake(.ended))
        #expect(!PlayerModel.keepsDeviceAwake(.failed))
    }

    @Test("The idle lock follows the state and is released on finish")
    func idleGuardFollowsPlayback() async {
        let host = HostDouble()
        var written: [Bool] = []
        let model = PlayerModel(
            target: target(),
            engine: host,
            source: SourceSpy(),
            idleGuard: { written.append($0) }
        )

        // The tick sees a picture: the lock is set exactly once, not anew at
        // every tick — the system should not be written to every half
        // second.
        host.engine.status = .playing
        await model.tick()
        await model.tick()
        #expect(written == [true])

        // Pausing releases it: whoever pauses and leaves should get the screensaver.
        host.engine.status = .paused
        await model.tick()
        #expect(written == [true, false])

        // Continue in picture, then the view ends: ``finish()`` cleans up
        // unconditionally. A lock that outlived the view would keep the TV
        // awake all night.
        host.engine.status = .playing
        await model.tick()
        model.finish()
        #expect(written == [true, false, true, false])
    }

}
