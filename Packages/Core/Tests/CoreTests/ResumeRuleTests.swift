import Foundation
import Testing

@testable import Core

/// **On-device test 2026-09-28:** "The Ember Warden Returns" at 110 s of 151.3 min (1.2 %) —
/// Jellyfin lists it as resumable, the app offered "Play".
@Suite("Resume: the server decides")
struct ResumeRuleTests {

    private let dark = PlaybackProgress(position: 110, duration: 164.6 * 60, runsOnServer: true)

    @Test("1.1 % with the server verdict is resumable and starts at 110 s")
    func serverVerdict() {
        #expect(dark.isResumable)
        #expect(PlaybackProgress.startPoint(state: dark, length: nil) == 110)
    }

    @Test("If the server says no, it is no — even in the middle of a film")
    func serverNo() {
        #expect(!PlaybackProgress(position: 3000, duration: 6000, runsOnServer: false).isResumable)
    }

    @Test("Without a server, Jellyfin thresholds apply: from 1 %, up to 90 %")
    func withoutServer() {
        #expect(PlaybackProgress(position: 70, duration: 6000).isResumable)
        #expect(!PlaybackProgress(position: 30, duration: 6000).isResumable)
        #expect(!PlaybackProgress(position: 5500, duration: 6000).isResumable)
    }

    @Test("Watched is never resumable")
    func seen() {
        #expect(
            !PlaybackProgress(position: 110, duration: 6000, isWatched: true, runsOnServer: true).isResumable)
    }
}
