import Core
import Foundation
import Observation

/// **"Start automatically as …"** — whoever switches this device on is mostly the same
/// person (AP45, 2026-09-23).
///
/// **Per device and explicitly not per profile.** The TV in the living room starts as
/// "Family", the one in the kids' room as "Kids". A value that traveled along would make the
/// setting of one device that of the other — and the kids' room would be
/// the case where that shows.
///
/// **Hence `UserDefaults` and not the profile book.** It lives next to
/// ``ParentalControls/ChildMode``, for the same reason: Both describe this device
/// and not this human. A secret is neither of the two — the PIN lives
/// elsewhere.
///
/// **If nothing is set here, "Who's watching?" appears.** That is not an error case but the
/// normal case of a household device.
@MainActor
@Observable
public final class StartChoice {

    /// **Not a language key but a store key** — the same own
    /// namespace as with ``ParentalControls/ChildMode``, also for `scripts/strings.py`.
    private static let key = "profile.startetAls"

    private let store: UserDefaults

    /// What was chosen last. `nil` means "ask every time".
    ///
    /// Observable and not fetched from the store on every read: A computed
    /// property over `UserDefaults` reports no change, and the switch in the sheet
    /// would jump back when flipped.
    public private(set) var identifier: Profile.Identifier?

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.identifier = store.string(forKey: Self.key).map(Profile.Identifier.init(rawValue:))
    }

    public func set(_ fresh: Profile.Identifier?) {
        identifier = fresh
        if let fresh {
            store.set(fresh.rawValue, forKey: Self.key)
        } else {
            store.removeObject(forKey: Self.key)
        }
    }

    /// The profile this device should start as — or `nil`.
    ///
    /// **Checked against the book and not believed blindly.** A deleted profile may
    /// not determine a start; otherwise at the next switch-on the device would face an
    /// ID that belongs to nobody, and the UI would have to make something up.
    /// The same rule as in ``ProfileBook/switchTo(zu:)``.
    ///
    /// **The ID stays in place meanwhile.** It is forgotten only when someone sets a
    /// new one — a profile that is just not in the book at the moment (sync not yet
    /// run) should apply again after the next pass.
    public func applies(in ledger: ProfileBook) -> Profile? {
        guard let identifier else { return nil }
        return ledger.profile.first { $0.identifier == identifier }
    }
}

extension StartChoice {

    /// Applies the choice at startup — **and never past a PIN.**
    ///
    /// **That is the actual rule of this setting.** "Always start as Dad" is
    /// convenient and would be a hole if it skipped the keypad: It lives in
    /// `UserDefaults` and thus **not** behind the lock — whoever stands at the device can
    /// set it. A child who sets it to an adult profile and restarts would otherwise have
    /// circumvented parental controls in two steps.
    ///
    /// That is not accomplished here but by
    /// ``ProfileSwitch/switchTo(zu:in:keychain:deviceStore:ledgerStore:pin:)``: Without a
    /// PIN it returns ``ProfileSwitch/SwitchOutcome/pinRequired`` and leaves the book
    /// untouched. This method passes that on instead of bypassing it — the UI
    /// then asks and switches itself.
    ///
    /// - Returns: `nil` if there is nothing to do — no choice set, the chosen profile
    ///   no longer exists, or it is already the one in front.
    @discardableResult
    public func apply(
        in ledger: inout ProfileBook,
        keychain: SecureStore,
        deviceStore: any KeyValueStore,
        ledgerStore: any KeyValueStore
    ) -> ProfileSwitch.SwitchOutcome? {
        guard let target = applies(in: ledger) else { return nil }
        guard target.identifier != ledger.active else { return nil }
        return ProfileSwitch.switchTo(
            zu: target.identifier, in: &ledger, keychain: keychain,
            deviceStore: deviceStore, ledgerStore: ledgerStore)
    }
}
