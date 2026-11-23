import Core
import Testing

@testable import FeaturesPhone

/// **The screen saver during Live TV** (2026-10-19): On the phone nobody set the
/// idle lock; `AVPlayer` kept movies awake, the own Live engine not.
@Suite("Player · idle lock")
struct IdleLockTests {

    @Test(
        "Awake while showing, loading and buffering",
        arguments: [
            PlaybackStatus.playing, .opening, .buffering,
        ])
    func awake(_ status: PlaybackStatus) {
        #expect(IdleLock.keepsAwake(status))
    }

    @Test(
        "Free on pause, end, failure and idle",
        arguments: [
            PlaybackStatus.paused, .ended, .failed, .idle,
        ])
    func unrestricted(_ status: PlaybackStatus) {
        #expect(!IdleLock.keepsAwake(status))
    }
}
