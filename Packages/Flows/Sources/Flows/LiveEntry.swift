import Core
import Foundation

/// **Whether "Live" opens the last watched channel right away — one rule for both devices**
/// (decision 27, C14, 2026-09-26).
///
/// The switch for it is ``Core/LivePreferences/showsBrowseArea`` ("Show overview before
/// playback"), **off by default** (user request 08-29: "the preview area is needed
/// only for channel search etc. … but not everyone needs it"). Until 2026-09-26
/// it existed only on the TV; the phone built its overview unconditionally, and the
/// switch had been dropped there on 09-07 because it did nothing.
public nonisolated enum LiveEntry {

    /// The rule — as a pure computation, so that it is checked.
    ///
    /// - Parameters:
    ///   - ausgefallen: The remembered channel was no longer there on the last attempt. Without
    ///     this case a spinner would stand forever, because the jump silently does nothing.
    ///   - gesprungen: A jump has already happened in this session. **Once and not
    ///     on every entry** — whoever leaves the player gets the overview; that is
    ///     the way back, and it stays.
    ///   - spielt: A channel is currently running that was jumped into from here. For as long as that lasts,
    ///     the loading surface is shown and not the overview — otherwise it would load its catalog
    ///     and its preview under the player, a second stream with a provider with one
    ///     permitted connection (viewer finding 09-02).
    ///   - uebersicht: the switch.
    ///   - gemerkt: whether there is a last watched channel at all. On first launch
    ///     the overview applies; a jump into nothing would be worse than an interim picture.
    public static func jumpsDirectly(
        failed: Bool, jumped: Bool, isPlaying: Bool, overview: Bool, remembered: Bool
    ) -> Bool {
        if failed { return false }
        if jumped { return isPlaying }
        if overview { return false }
        return remembered
    }
}
