import Core
import Foundation
import Playback
import Testing

@testable import FeaturesPhone

/// What a title starts with — audio **and** subtitles.
///
/// **The finding (E45):** The subtitle level ("never / forced only / always") has lain since
/// 2026-09-07 in the shared ``Core/AudioPreference``, traveled along via the handoff to a
/// new device — and was **saved without ever being applied.** The player
/// instead rebuilt half the rule: only the audio, only the anime case.
///
/// **What is checked here is the translation.** The rule itself is in `Core` and
/// has its checks there; what is new is the bridge between two ID spaces —
/// `MediaTrack.id` is a text, `PlaybackTrack.id` a number. Exactly there it went no
/// further until today.
@Suite("Start tracks")
struct StartTrackTests {

    private func track(_ id: String, language: String?, forced: Bool = false) -> MediaTrack {
        MediaTrack(
            id: id, kind: .audio, title: "", language: language, isDefault: false,
            isForced: forced)
    }

    /// **The number is the track's position in the file**, and the server's text is
    /// the same number. ``Core/PlaybackTrack/fromServer(_:)`` translates that way, and this place
    /// must do exactly the same — otherwise the engine would choose a different track than the one meant.
    @Test("The server's text identifier becomes the engine's track number")
    func trackNumberFromText() {
        #expect(JellyfinPlayerSource.trackNumber(track("3", language: "ja")) == 3)
        #expect(JellyfinPlayerSource.trackNumber(track("0", language: "de")) == 0)
    }

    /// **The case that would have silently gone wrong.** An external subtitle file carries
    /// an ID that is not a track number. Inventing a number from it would mean choosing
    /// some track at start — and the same wrong one every time.
    @Test("What is not a track number selects nothing")
    func noNumberSelectsNothing() {
        #expect(JellyfinPlayerSource.trackNumber(track("extern-de-1", language: "de")) == nil)
        #expect(JellyfinPlayerSource.trackNumber(nil) == nil)
        #expect(JellyfinPlayerSource.trackNumber(track("", language: nil)) == nil)
    }

    /// Without a selection the file's default stays — the job then carries nothing.
    @Test("A job without start tracks selects nothing")
    func jobWithoutChoice() {
        let job = PlaybackRequest(
            identifier: "a", title: "Asil", address: URL(string: "http://x/y")!)

        #expect(job.startAudio == nil)
        #expect(job.startSubtitle == nil)
    }
}
