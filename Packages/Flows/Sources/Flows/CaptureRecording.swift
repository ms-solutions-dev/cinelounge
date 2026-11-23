import Core
import Diagnose
import Observation

/// The switch "record verbosely" — **at all places at once, on both devices.**
///
/// **The first shared flow** (AP58 R0), and it is small because it is meant to prove the
/// wiring and no more. Until 2026-09-26 it stood twice, and the two
/// versions drifted apart:
///
/// - **TV** (`DiagnosticsSettings`): store, `DebugMode.current` and a marker in
///   the recording ("— Recording switched on —").
/// - **Phone** (`DiagnoseView`): store, `DebugMode.current` and the size of the
///   error ledger — **without** the marker. A gap in the recording had no
///   explanation there, only a suspicion.
///
/// The shared version does all of that. It sets the size of the error ledger through
/// `Diagnose.setVerbose`, which has nothing to do on the TV.
@Observable
public final class CaptureRecording {

    /// Whether verbose recording is on — as the store says.
    public private(set) var on: Bool

    /// **Whether the diagnostics offer developer tools** — today the state view
    /// (on-device test build 1332, finding 9).
    ///
    /// **No switch of its own:** Verbose recording is already the mode that
    /// only someone checking something switches to. In the TestFlight and Store build nobody stumbles
    /// over twenty simulated failures; whoever needs them flips the switch, and
    /// the row is there. Both apps ask here so that the rule does not drift apart.
    public var showsDeveloperTools: Bool { on }

    private let store: any KeyValueStore

    /// - Parameter ablage: Where the switch survives a restart. The checks pass
    ///   one of their own so that they do not write to the computer's Keychain.
    public init(store: any KeyValueStore = SecureStore()) {
        self.store = store
        self.on = DebugMode.load(from: store).isOn
    }

    /// Flips the switch.
    ///
    /// The order counts: first the store, then the effective state, then the marker.
    /// The other way round, the marker "switched on" would stand in a recording that would be
    /// off again the same moment after a crash.
    public func setEnabled(_ fresh: Bool) {
        on = fresh
        let mode = DebugMode(isOn: fresh)
        mode.save(to: store)
        DebugMode.current = mode
        Diagnose.setVerbose(fresh)
        Diagnostics.noteRecordingSwitch(isOn: fresh)
    }
}
