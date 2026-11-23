import Foundation

/// **What a TV is called on the home network — both rules in one place** (AP58 R5, finding
/// Z1, 2026-09-26).
///
/// **Two names because they are two jobs**, and until 2026-09-26 they sat in two
/// different places on the TV without either knowing about the other:
///
/// - ``remote``: The remote's service stays up as long as the app runs,
///   and the phone **shows it in a list**. It is named like the device.
/// - ``handoff()``: The handoff's service applies only for the three minutes of a code,
///   and the phone finds it through the code, not through a list. It gets a
///   random name.
public enum ServiceName {

    /// The name from the system settings — **and not "CineLounge"**.
    ///
    /// Whoever named their Apple TV "Living Room" searches for "Living Room" on the phone. In
    /// a house with two Apple TVs, a list of "CineLounge" twice would not be a choice
    /// but a coin toss — and you would only notice when the film stops in the wrong room.
    public static var remote: String {
        #if canImport(UIKit)
            let own = ProcessInfo.processInfo.hostName
                .replacingOccurrences(of: ".local", with: "")
            return own.isEmpty ? "CineLounge" : own
        #else
            return "CineLounge"
        #endif
    }

    /// A name with a random ending — `CineLounge-7KQ2`.
    ///
    /// **Not the device name**: Two devices of the same name on the same network would be two
    /// services fighting over the same entry; which one the phone then finds
    /// is decided by the order of the replies. Four characters without confusable ones (`0`/`O`,
    /// `1`/`I`) are enough: They only stand for the minutes in which the code applies.
    public static func handoff() -> String {
        var random = SystemRandomNumberGenerator()
        return handoff(random: &random)
    }

    static let character = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func handoff<Generator: RandomNumberGenerator>(random: inout Generator) -> String {
        "CineLounge-" + String((0..<4).map { _ in character.randomElement(using: &random)! })
    }
}
