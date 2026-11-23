import Foundation
import SwiftUI

/// Feedback through the finger.
///
/// It does not exist on the TV and on the phone it is half of the answer: where a swipe
/// gesture clicks into place, where a level hits its limit, where a PIN is wrong.
///
/// **The rule by which things are decided here.** A feedback confirms an event that the
/// viewer triggered and whose result they **otherwise do not see, or see only later**. It
/// replaces no visible answer, and it accompanies no ordinary button press that immediately
/// does something visible. An app that twitches at every touch is worse than a silent one:
/// what always comes no longer communicates anything — it is read as a property of the
/// device and not as an answer to one's own action.
///
/// **What explicitly gets nothing**, so that the list is not up for debate again with the
/// next building block:
///
/// - **Paging in the header area** (`Pager`). The change is the most visible event
///   of the whole app — a full-screen image is swapped. And it happens dozens of times per
///   session; exactly that turns it into a property of the device.
/// - **The keys of the number pad.** A dot fills at the same moment, and four jolts for a
///   four-digit PIN are a shaking, not information.
/// - **Filter chips, segments, tab switches.** The chip fills, the list rebuilds. For the
///   segment the system would bring its own feedback anyway — a second one next to it would
///   be a double beat.
/// - **The correct PIN.** Only the failed attempt reports; success is shown by the door that
///   opens. The same split as with the system's password, and for the same reason: whoever
///   typed correctly already knows.
/// - **A command from the swipe tray** (remove account, delete list). The row disappears
///   under the finger — that is the answer. Technically it would not even arrive there: the
///   view that would carry the state is gone by the next pass.
///
/// **`sensoryFeedback` and not `UIImpactFeedbackGenerator`** (2026-09-07). Until then there were
/// four functions here with UIKit generators behind `#if canImport(UIKit)`, and exactly
/// **one** call site in the whole project. Three reasons for the switch: the modifier hangs
/// on a **state** instead of a call and therefore cannot be forgotten in a branch that runs
/// rarely; it needs no platform switch and thus is compiled in the macOS build with which
/// the checks run on the computer; and it respects the user's system settings by itself,
/// which a hand-built generator does not.
public enum Haptics {

    /// Where the switch lives — **one key and not two**, as with
    /// ``ColorBoard/storeKey``. Area 6 (Controls) writes it, this file reads it; two
    /// identical strings in two places drift apart exactly when someone renames one of them.
    public static let storeKey = "app.haptics"

    /// Whether the app may give feedback at all.
    ///
    /// **Read and not held.** A mutable state here would be a second place for the same choice —
    /// and the second is the one you forget when changing. If the entry is missing, feedback is
    /// on: whoever has set nothing gets what iOS considers usual.
    public static var isOn: Bool {
        UserDefaults.standard.object(forKey: storeKey) as? Bool ?? true
    }

    /// The occasions this app knows — **four, and each names its own in the name.**
    ///
    /// No `leicht`, `mittel`, `heavy`: a strength is no meaning, and a list of strengths invites
    /// taking the next larger one at some place because it is "more important". An occasion, by
    /// contrast, can be checked — it applies or it does not.
    public enum Occasion: Sendable {

        /// A selection has flipped, and only a small fill is visible — Watched, Favorite.
        case switched

        /// Something has clicked into place: a row in its tray, a pull at its threshold, a level at
        /// the stop. **The main case on the phone** — a gesture without a detent feels unsure, and
        /// neither color nor motion helps against that.
        case snapped

        /// An action went through whose result takes a while.
        ///
        /// **Not for the next screen.** Whoever opens a view sees it; this is about the pickup, where
        /// for seconds nothing happens and afterwards the same list stands there with different
        /// content.
        case succeeded

        /// An action did not work.
        ///
        /// Only where the screen says so **too**: a shaking without a sentence next to it is an
        /// error message that cannot be reread.
        case rejected

        var pattern: SensoryFeedback {
            switch self {
            case .switched: .selection
            case .snapped: .impact(weight: .light, intensity: 0.6)
            case .succeeded: .success
            case .rejected: .error
            }
        }
    }
}

extension View {

    /// Gives feedback as soon as `value` becomes a different one.
    ///
    /// **On the state and not on the call.** A call sits in a branch; a state applies to all
    /// paths that reach it — also to the one someone adds later.
    public func haptics<Value: Equatable>(_ reason: Haptics.Occasion, at value: Value) -> some View {
        haptics(reason, at: value, when: { _, _ in true })
    }

    /// Gives feedback when the change of `value` satisfies the condition.
    ///
    /// **The condition is the rule and not the exception.** Almost every state that feedback
    /// hangs on falls back afterwards — the hit mark to `nil`, the open tray to closed, the
    /// failed attempt after four hundred milliseconds to false. Without a condition the feedback
    /// would come twice every time: once for the event and once for the cleanup afterwards.
    ///
    /// - Parameter applies: Receives the old and the new value.
    public func haptics<Value: Equatable>(
        _ reason: Haptics.Occasion, at value: Value, when applies: @escaping (Value, Value) -> Bool
    ) -> some View {
        sensoryFeedback(trigger: value) { old, fresh in
            guard Haptics.isOn, applies(old, fresh) else { return nil }
            return reason.pattern
        }
    }
}
