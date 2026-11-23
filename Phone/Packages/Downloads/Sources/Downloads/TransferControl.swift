/// Pause and resume — **in the row, not in the dialog.**
///
/// **Two separate targets in one row:** the title part opens the menu for the title, the
/// button on the right operates the transfer. There are no nested targets — the same
/// pattern as in the sports list, where previously two of seven rows did not respond because
/// they looked the same and were not.
public enum TransferControl {

    /// What the button on the right currently does.
    public enum Action: String, Sendable, Hashable {
        case pause = "anhalten"
        case resume = "fortsetzen"
        /// Nothing — finished or waiting. **The button then disappears** instead of staying
        /// there dimmed.
        case none = "keine"
        case retry = "erneutVersuchen"
    }

    public static func action(forItem state: Transfer.Situation) -> Action {
        switch state {
        case .isLoading: .pause
        case .idle(let reason):
            // Without a network there is nothing to resume; the button would be an invitation that
            // repeats the same message when pressed.
            reason == .noNetwork ? .none : .resume
        case .waitingForConnection: .none
        case .failed: .retry
        case .done: .none
        }
    }

    /// **The VoiceOver label travels along.** A button whose image changes
    /// and whose label does not says the wrong thing in the screen reader until the next launch
    /// — and nobody sees it.
    public static func label(forItem action: Action) -> String {
        switch action {
        case .pause: "common.pause"
        case .resume: "stock.resume"
        case .retry: "common.retry"
        case .none: ""
        }
    }
}
