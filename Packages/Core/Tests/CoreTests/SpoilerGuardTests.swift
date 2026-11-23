import Testing

@testable import Core

/// **Spoiler protection** (AP85, 2026-11-09): only unseen, unstarted episodes, only when on.
@Suite("Spoiler guard")
struct SpoilerGuardTests {

    @Test("Hidden only when on, unwatched and not started")
    func rule() {
        #expect(SpoilerGuard.hides(watched: false, started: false, enabled: true))
        #expect(!SpoilerGuard.hides(watched: false, started: false, enabled: false))
        #expect(!SpoilerGuard.hides(watched: true, started: false, enabled: true))
        #expect(!SpoilerGuard.hides(watched: false, started: true, enabled: true))
    }
}
