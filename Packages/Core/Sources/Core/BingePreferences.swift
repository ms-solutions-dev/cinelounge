import Foundation

/// What a binge needs — **per profile** (AP85 binge package, Max 2026-11-09).
///
/// Three switches that only make sense for someone watching episode after episode:
/// skip intro and recap by themselves, hide what unseen episodes give away, and ask after a
/// few episodes without a key press whether anyone is still watching.
///
/// **In the profile and not on the device**, like the audio preference: one person binges
/// with spoiler protection, the other wants the stills. The keys move with the profile
/// (``ProfileStore/playbackKeys``).
public struct BingePreferences: Sendable, Equatable {

    /// Skip intro and recap without a press. Off by default: someone who has never seen the
    /// series wants its opening once.
    public var skipsIntro: Bool
    /// Unseen episodes without still and description. Off by default.
    public var hidesSpoilers: Bool
    /// After how many episodes in a row without a key press the player asks "Still
    /// watching?" — `0` never.
    public private(set) var stillWatchingAfter: Int

    public static let defaultStillWatching = 3
    /// The choices offered — "never", three, five.
    public static let stillWatchingChoices = [3, 5, 0]

    public init(
        skipsIntro: Bool = false, hidesSpoilers: Bool = false,
        stillWatchingAfter: Int = BingePreferences.defaultStillWatching
    ) {
        self.skipsIntro = skipsIntro
        self.hidesSpoilers = hidesSpoilers
        self.stillWatchingAfter = max(0, min(stillWatchingAfter, 20))
    }

    /// The sections skipped without a press. Never the credits: they lead to the next-episode
    /// offer, which has its own counter.
    public var autoSkipKinds: Set<MediaSegment.Kind> {
        skipsIntro ? [.intro, .recap] : []
    }

    // MARK: - Storage

    static let introKey = "binge.skipIntro"
    static let spoilerKey = "binge.hideSpoilers"
    static let stillWatchingKey = "binge.stillWatching"

    public static func load(from store: any KeyValueStore) -> BingePreferences {
        let intro = (try? store.value(for: introKey)) == "on"
        let spoiler = (try? store.value(for: spoilerKey)) == "on"
        let after = (try? store.value(for: stillWatchingKey)).flatMap(Int.init) ?? defaultStillWatching
        return BingePreferences(skipsIntro: intro, hidesSpoilers: spoiler, stillWatchingAfter: after)
    }

    /// **One writer per key**, as with ``AudioPreference``: whoever toggles one switch must
    /// not write the inherited value of another into the profile as its own.
    public static func writeSkipsIntro(_ on: Bool, in store: any KeyValueStore) {
        try? store.set(on ? "on" : "off", for: introKey)
    }

    public static func writeHidesSpoilers(_ on: Bool, in store: any KeyValueStore) {
        try? store.set(on ? "on" : "off", for: spoilerKey)
    }

    public static func writeStillWatchingAfter(_ episodes: Int, in store: any KeyValueStore) {
        try? store.set(String(max(0, episodes)), for: stillWatchingKey)
    }
}
