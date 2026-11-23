import Foundation

/// Which playback engine the viewer prefers.
///
/// **What is left of it, and why** (AP8, 2026-09-02). This choice was a
/// troubleshooting tool: as long as it was unclear whether Apple's engine runs more smoothly
/// via the server's chunking or VLC on the raw file in the living room,
/// it had to be switchable. The question has been answered twice
/// — first by measurement (HLS with fMP4 segments), then by the
/// product decision of 2026-08-15: no more solution paths with VLC.
///
/// **The `alwaysVLC` case is therefore gone.** It had no effect anyway:
/// ``PlaybackEngineSelector`` accepted the preference as a parameter and read
/// it **not a single time** in its body — at three call sites a Keychain was
/// opened for it, for a value nobody read (finding 2026-08-24).
///
/// **And the two remaining cases stay as an enum**, although they
/// mean the same thing today: they are the store key of a viewer who
/// once chose something. A store that reads an unknown value
/// falls back to ``automatic`` — also an earlier saved `alwaysVLC`.
public enum PlaybackPreference: String, CaseIterable, Sendable, Identifiable {

    /// The rule decides.
    case automatic
    /// Where possible, Apple's engine via the server's chunking.
    ///
    /// Since the VLC removal the default of the rule itself — the case stays so that
    /// an earlier choice does not appear as an unknown value.
    case preferNative

    public var id: String { rawValue }

    static let storageKey = "playback.enginePreference"

    public static func load(from store: any KeyValueStore) -> PlaybackPreference {
        PlaybackPreference(rawValue: (try? store.value(for: storageKey)) ?? "") ?? .automatic
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(rawValue, for: Self.storageKey)
    }
}
