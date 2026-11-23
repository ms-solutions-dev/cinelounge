import Foundation

/// What the PIN is being asked for right now.
///
/// **Without a task the sheet does not open at all** — this is the place where the prototype
/// checked itself. A keypad without a reason in front of it is a question without a
/// sentence: the parent does not know what they are releasing, and the child sees a screen
/// that looks like nothing.
///
/// **The sentence belongs to the task and not to the sheet.** Otherwise the sheet would have
/// to keep a table over tasks — and that would then exist twice.
public enum PinTask: Sendable, Equatable {

    /// Choose another account.
    case accountSwitch

    /// Open a locked door — the reason comes from ``LockedDoors``.
    case door(identifier: String, reason: String)

    /// Change the PIN itself. **Requires the old one**, otherwise it would be superfluous at the
    /// moment someone wants to change it.
    case changePin

    /// Assign the PIN for the first time. **Does not ask** but sets — there is none yet.
    case assignPin

    /// The key for the sheet's heading.
    public var headline: String {
        switch self {
        case .accountSwitch: "pin.enter"
        case .door: "pin.enter"
        case .changePin: "pin.enterOld"
        case .assignPin: "pin.enterNew"
        }
    }

    /// The explanatory sentence — for a door **its own**, otherwise a fixed one.
    ///
    /// For a door a finished sentence: ``LockedDoors/reason(_:)`` already translates it
    /// (since the final step of AP58 from the shared catalog, before that German raw text). The
    /// three fixed ones arrive as keys.
    public var message: Wording {
        switch self {
        case .accountSwitch: .key("childLock.ask.switchAccount.text")
        case .door(_, let reason): .wording(reason)
        case .changePin: .key("childLock.ask.change.text")
        case .assignPin: .key("childLock.ask.create.text")
        }
    }

    /// A key is translated, a wording stands as it is.
    public enum Wording: Sendable, Equatable {
        case key(String)
        case wording(String)
    }

    /// Whether this task checks an existing PIN — or sets a new one.
    public var verifies: Bool { self != .assignPin }
}
