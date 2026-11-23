import Synchronization

/// **What `NetworkStatus` tells about its decisions — without depending on a logging
/// package** (on-device test build 1332, finding 11, 2026-09-27).
///
/// **The finding:** On the device it said "The Apple TV is only reachable on the home
/// network" although the phone was on Wi-Fi — and the diagnostic report did not say why.
/// Network path, tunnel and location are decided here, but the package **deliberately
/// depends on nothing**: StoryShelf includes it via the path
/// (`../../../cinelounge-phone/Packages/Netzlage`), and a dependency on `Diagnose` would
/// pull this app's error ledger in there.
///
/// **Hence a hook instead of an import.** The app sets it once
/// (``set(_:)``) and routes the sentences into its own log. **Without a hook the package
/// is silent** — exactly as it has been until now; StoryShelf notices nothing.
///
/// **No addresses, no names in the sentence.** What is here are kinds (Wi-Fi, tunnel),
/// interface names (`en0`, `utun3`) and numbers — nothing that gives away a home network.
public enum NetworkLog {

    /// How heavy a sentence weighs — the app maps it to its own levels.
    public enum Tier: Sendable, Equatable {
        /// An ordinary step — only relevant for verbose recording.
        case step
        /// Something that explains a message on screen — belongs in every report.
        case hint
    }

    public typealias Output = @Sendable (Tier, String) -> Void

    private static let output = Mutex<Output?>(nil)

    /// Sets the hook — `nil` makes the package silent again.
    public static func set(_ fresh: Output?) {
        output.withLock { $0 = fresh }
    }

    /// Writes a sentence **if someone is listening** — otherwise it is not even built.
    static func note(_ tier: Tier, _ message: @autoclosure () -> String) {
        guard let target = output.withLock({ $0 }) else { return }
        target(tier, message())
    }
}
