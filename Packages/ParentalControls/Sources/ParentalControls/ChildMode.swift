import Diagnose
import Foundation
import Observation

/// Child mode as a **device state** — "what is locked right now".
///
/// **Decided on 06.09. (question 3, answer c): profile *and* device state, and kept
/// separate.** A child account says **who owns the progress** — that is a property of the
/// account and lives with the account (``AccountKind``, `AccountsModel`). What is locked right
/// now, by contrast, hangs on the **device**: a child who gets an adult's phone in hand has
/// no account of its own, and a child account at which an adult is sitting right now needs
/// to lock nothing. Only this version carries both cases.
///
/// **The switch locks nothing yet, and it says so next to it.** The sixteen doors
/// (``LockedDoors``), the PIN (``Pin``) and the ``TabScope`` are in the package
/// **Parental controls** of the roadmap and are not built yet; what is here is the state they
/// will hang on. A switch that **pretends** to lock would be the most serious finding of the
/// usability pass again — there, four taps led from the child account to the "Adult
/// channels" switch, without a PIN. That is why the row in the sheet says explicitly what
/// happens today and what does not yet.
///
/// **And that is why switching off does not ask today.** The state comes from the market:
/// creating is trivial, all the work is in **leaving** — Disney+ demands four spelled-out
/// digits instead of a PIN, because a PIN is learned by watching. As long as there is no PIN,
/// every hurdle here would be a pretended one.
///
/// **In the standard store and not in the Keychain.** That this phone is in child mode right
/// now is no secret. The **PIN** is one, and it lives elsewhere.
@MainActor
@Observable
public final class ChildMode {

    /// **Not a language key but a store key.** The namespace of its own keeps the two apart â
    /// also for `scripts/strings.py`.
    /// Public for the one-time migration (``Flows/ParentalControlsMigration``), which runs before any
    /// UI and therefore cannot build this class.
    public nonisolated static let key = "childMode.on"

    private let store: UserDefaults

    /// Whether this device is in child mode right now.
    ///
    /// Observable and not fetched from the store on every read: a computed property over
    /// `UserDefaults` reports no change, and the switch in the sheet would jump back when
    /// flipped.
    public private(set) var on: Bool

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.on = store.bool(forKey: Self.key)
    }

    public func set(_ fresh: Bool) {
        on = fresh
        store.set(fresh, forKey: Self.key)
        // **The rule source "device lock".** Whoever searches the log for why a lock takes effect or
        // no longer takes effect finds the time here — without the line saying anything about the
        // account.
        Diagnose.hint(.parentalControls, "Device lock: \(fresh ? "on" : "off")")
    }
}
