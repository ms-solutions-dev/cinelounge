import Foundation

// **`canImport` alone is not enough here** (2026-09-10, noticed when moving this package to
// the TV): On tvOS `LocalAuthentication` can be imported, but
// `LAContext` is explicitly marked **unavailable** in it. The condition
// therefore reported "exists", and the build broke with five lines of "is unavailable in tvOS".
#if canImport(LocalAuthentication) && !os(tvOS)
    import LocalAuthentication
#endif

/// Face ID as an **approval** before credentials leave the phone.
///
/// **Explicitly not a passkey.** A passkey identifies to a **server**, and
/// there is none here — that is the core of E5: no account, no cloud, no server.
/// What is checked here is not *who* agrees but *that* someone agrees who
/// can unlock the phone. Whoever confuses the two builds in an account because they
/// think they need one.
///
/// **Why it exists at all, although the QR authenticates itself.** The code proves
/// proximity: Whoever sees the screen is standing in front of it. It does not prove who owns the phone —
/// and access tokens and passwords leave the phone. An unlocked phone left lying around
/// would, without this question, set up a stranger's TV.
public struct AccessGrant: Sendable {

    public enum Outcome: Sendable, Equatable {
        case isAllowed
        /// The viewer cancelled — **not an error.**
        case wasCancelled
        /// The device cannot ask (no passcode, no biometrics).
        case notPossible
    }

    public init() {}

    /// Asks.
    ///
    /// **With the device passcode as a fallback and not biometrics only.** `deviceOwnerAuthentication`
    /// accepts both; whoever has switched off Face ID or wears a mask should still be able to set up
    /// their TV. An approval that knows only one method
    /// locks out people who just wanted to prove it.
    public func query(reason reasonText: String) async -> Outcome {
        #if canImport(LocalAuthentication) && !os(tvOS)
            let check = LAContext()
            var cause: NSError?
            guard check.canEvaluatePolicy(.deviceOwnerAuthentication, error: &cause) else {
                return .notPossible
            }
            do {
                let isAllowed = try await check.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: reasonText)
                return isAllowed ? .isAllowed : .wasCancelled
            } catch {
                // bewusst still: A cancellation is the normal case of this prompt and not an
                // incident. Whoever taps it away has decided — writing them into the book for it
                // would mean logging every decision.
                return .wasCancelled
            }
        #else
            // **On the Mac and on the TV there is no approval.** On the Mac only `swift test`
            // runs; on the TV there is nothing to approve — it is
            // the **receiving** side, and nothing goes out of it during a handoff. Whoever built a prompt in here
            // would be asking the wrong person.
            return .notPossible
        #endif
    }
}
