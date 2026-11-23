import Core
import Diagnose
import Foundation
import Observation
import ProfileKit

/// Set, change, remove the profile PIN — **and "forgot PIN" before it** (AP52;
/// merged in AP58 R2, finding P2).
///
/// **The finding:** The TV ran the flow in the view (`ProfilePinManagement`:
/// choice → old → new), the phone in a sheet of its own (`ProfilePinPanel`) with a
/// second copy of the same steps. The rules themselves were already shared in
/// ``ProfileKit/ProfilePINMaintenance``; the steps in between — when the old one is asked for, what
/// comes after it, where "Back" leads from the way out — existed twice.
///
/// **The parental controls door is not here**, but at the call site
/// (``ParentalControls/LockedDoors`` "profilpin"); whether it asks depends on the
/// interface's rule. The old PIN proves whom the profile belongs to; the door, that an adult
/// is sitting in front of it.
///
/// **The latch before a switch does not check here**, but in the switch itself
/// (``ProfileKit/ProfileSwitch``). The situation ``Situation/lock`` holds only the step for the
/// number pad and the way out in front of it.
@Observable
public final class ProfilePinFlow {

    /// What the flow was opened for.
    public enum Situation: Sendable, Equatable {
        /// Set, change or remove.
        case maintain
        /// The latch before switching to this profile.
        case lock
    }

    /// Where the flow stands.
    public enum Step: Sendable, Equatable {
        /// Change or remove?
        case choice
        /// The old PIN, then a new one.
        case oldPinForChange
        /// The old PIN, after which it is gone.
        case oldPinForRemoval
        /// The new PIN, twice — `old` is the proof, `nil` for the first.
        case fresh(old: String?)
        /// The number pad before the switch.
        case lock
        /// „PIN vergessen“.
        case recovery
    }

    /// What the old PIN accomplished.
    public enum OldPin: Sendable, Equatable {
        /// Wrong — the pad stays. Nothing is changed.
        case wrong
        /// Correct; on to the new one (``Step/fresh(old:)``).
        case next
        /// Correct, and the PIN is removed.
        case removed
    }

    public let profile: Profile
    public let state: Situation
    public private(set) var step: Step
    /// Where "Back" leads from the way out.
    private var previous: Step

    /// "Forgot PIN" — `nil` without an Apple account: Without the cloud there is no deadline and no
    /// second device to confirm; a button leading there would lead to a page that can do
    /// nothing.
    public let recovery: PinRecoveryFlow?

    private let keychain: any KeyValueStore
    private let cloud: ProfileCloud?

    /// The clock — replaceable for the checks; the way out comes along.
    @ObservationIgnored public var now: () -> Date = { Date() } {
        didSet { recovery?.now = now }
    }

    /// - Parameters:
    ///   - schluesselbund: where the PIN lives on the device — in the app the cloud's migration bundle
    ///     or the Keychain (the same one the latch reads).
    ///   - wolke: `nil` without an Apple account.
    public init(
        profile: Profile, state: Situation, keychain: any KeyValueStore, cloud: ProfileCloud?,
        device: String = DeviceName.thisDevice
    ) {
        self.profile = profile
        self.state = state
        self.keychain = keychain
        self.cloud = cloud
        self.recovery = cloud.map {
            PinRecoveryFlow(cloud: $0, lock: .profile(profile.identifier), device: device)
        }
        let start = Self.start(
            state, isSet: ProfilePIN(store: keychain, forItem: profile.identifier).isSet)
        self.step = start
        self.previous = start
    }

    /// The first step — **at the latch the number pad; otherwise, without a PIN, straight to setting**
    /// and, with a PIN, the choice first.
    public nonisolated static func start(_ state: Situation, isSet: Bool) -> Step {
        switch state {
        case .lock: .lock
        case .maintain: isSet ? .choice : .fresh(old: nil)
        }
    }

    /// Whether the profile carries a PIN.
    public var isSet: Bool { ProfilePIN(store: keychain, forItem: profile.identifier).isSet }

    /// Whether these digits are the PIN — **without opening anything.**
    public func matches(_ digits: String) -> Bool {
        ProfilePIN(store: keychain, forItem: profile.identifier).matches(digits)
    }

    // MARK: - The choice

    public func chooseChange() {
        guard step == .choice else { return }
        step = .oldPinForChange
    }

    public func chooseRemoval() {
        guard step == .choice else { return }
        step = .oldPinForRemoval
    }

    // MARK: - Alte und neue PIN

    /// The old PIN — **if it is correct, we go on; otherwise everything stays.**
    public func acceptOld(_ digits: String) -> OldPin {
        switch step {
        case .oldPinForChange:
            guard matches(digits) else { return .wrong }
            step = .fresh(old: digits)
            return .next
        case .oldPinForRemoval:
            let outcome = ProfilePINMaintenance.remove(
                old: digits, forItem: profile.identifier, keychain: keychain, cloud: cloud,
                now: now())
            Diagnose.step(.parentalControls, "Remove profile PIN: \(outcome)")
            return outcome == .removed ? .removed : .wrong
        case .choice, .fresh, .lock, .recovery:
            return .wrong
        }
    }

    /// Sets the new PIN — the first one without, every further one with the old one just checked.
    @discardableResult
    public func set(_ fresh: String) -> ProfilePINMaintenance.SwitchOutcome {
        guard case .fresh(let old) = step else { return .oldWrong }
        let outcome = ProfilePINMaintenance.set(
            fresh, old: old, forItem: profile.identifier, keychain: keychain, cloud: cloud,
            now: now())
        Diagnose.step(.parentalControls, "Set profile PIN: \(outcome)")
        return outcome
    }

    // MARK: - Forgotten PIN

    /// Opens the way out — **only with the cloud, and never when setting**: Where there is no PIN
    /// yet, there is nothing to forget.
    public func openRecovery() {
        guard recovery != nil, step != .recovery else { return }
        if case .fresh = step { return }
        previous = step
        step = .recovery
    }

    /// "Back" from the way out — to where it came from.
    public func back() {
        guard step == .recovery else { return }
        step = previous
    }

    /// The way out is due or confirmed — **the PIN falls household-wide**, as a tombstone
    /// in the cloud, and the request with it (``ProfileKit/ProfilePINMaintenance/redeem(forItem:keychain:cloud:now:)``).
    ///
    /// **Only what releases when freshly read** (``PinRecoveryFlow/redeem()``) — a running deadline
    /// is no proof, and neither is a request that another device has just cancelled.
    ///
    /// - Returns: whether it was released. At the latch the switch then continues without a PIN.
    public func redeemRecovery() async -> Bool {
        guard let recovery, await recovery.redeem() else { return false }
        ProfilePINMaintenance.redeem(
            forItem: profile.identifier, keychain: keychain, cloud: cloud, now: now())
        Diagnose.step(.parentalControls, "Profile PIN resolved via the fallback")
        return true
    }
}
