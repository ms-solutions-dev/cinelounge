import Core
import Diagnose
import Foundation
import Observation
import ProfileKit

/// "Forgot PIN" for **one** lock — read, request, cancel, release (AP58 R2,
/// finding P2).
///
/// **The finding:** The phone synced before reading (`household()?.reconcile()`), the
/// TV read the state synchronously from the mirror. A confirmation from the second device
/// therefore appeared on the TV only after the next round trip — it showed "waiting" where the
/// way out was already open. And release happened in two ways: on the TV without checking the
/// state at the moment of the press, on the phone via ``ProfileKit/PINFallback/State/resolves``.
///
/// **Now the same path on both devices:** first sync, then read; release happens only if
/// what was **freshly read** is due or confirmed. A request that another device has just
/// cancelled opens nothing here any more.
///
/// **What falls afterwards is stated by the caller** — the profile PIN (``ProfilePinFlow``) or the
/// device's parental controls. This flow only closes the request.
@Observable
public final class PinRecoveryFlow {

    public let lock: PINFallback.Lock
    /// The state read last.
    public private(set) var state: PINFallback.State = .none

    private let cloud: ProfileCloud
    private let device: String

    /// The device's clock — **only for display and checks**; whether a deadline has passed is
    /// computed by ``ProfileKit/PINFallback`` against the server's stamp.
    @ObservationIgnored public var now: () -> Date = { Date() }

    /// - Parameter geraet: how this device is named in the request.
    public init(
        cloud: ProfileCloud, lock: PINFallback.Lock, device: String = DeviceName.thisDevice
    ) {
        self.cloud = cloud
        self.lock = lock
        self.device = device
    }

    /// Reads the state — **after a round trip to the server**, so that a confirmation from another
    /// device arrives here.
    public func read() async {
        _ = await cloud.household()?.reconcile()
        state = cloud.pinState(forItem: lock, now: now())
    }

    /// Files the request — **a second one extends nothing**
    /// (``ProfileKit/ProfileCloud/requestPinRecovery(forItem:device:now:)``).
    public func request() {
        state = cloud.requestPinRecovery(forItem: lock, device: device, now: now())
        Diagnose.step(.parentalControls, "PIN fallback requested")
    }

    /// Withdraws the request — from any device, without PIN.
    public func cancel() {
        cloud.cancelPinRecovery(forItem: lock)
        state = .none
        Diagnose.step(.parentalControls, "PIN fallback canceled")
    }

    /// Closes the request **if it releases when freshly read** — otherwise nothing.
    ///
    /// - Returns: whether the caller may now drop the lock.
    public func redeem() async -> Bool {
        await read()
        guard state.resolves else { return false }
        cloud.closePinRecovery(forItem: lock)
        state = .none
        Diagnose.step(.parentalControls, "PIN fallback resolved")
        return true
    }
}
