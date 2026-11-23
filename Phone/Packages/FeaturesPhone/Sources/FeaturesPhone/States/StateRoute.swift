import Flows
import SwiftUI

/// Where the loud button of a state leads on the phone — **the thin mapping of
/// ``ActionTarget`` onto this app** (AP58 R3).
///
/// **Until 2026-09-26 every loud button on the phone did the same thing:** reload
/// — even under "Sign in again", "Check access" or "Add IPTV access". The
/// state did not know where it belonged; each call site passed along its one load action. Since
/// the state is shared, every job carries its target, and the phone implements
/// it here — the TV does the same in `MainView.go(zu:)`.
///
/// **Two kinds of target:**
///
/// * **Those of the call site** — ``ActionTarget/retry`` ("try again" is `start()` in the player,
///   `load()` in the Library) and ``ActionTarget/systemSettings``
///   (only the QR reader knows the camera). The call site's `action` handles them.
/// * **Those of the ``Navigator``** — everything that leads to another view. That is handled by the
///   environment value ``StateRouteKey``, which the shell sets once; the locks and
///   the PIN question of the ``Navigator`` apply as for any other path.
enum StateRoute {

    /// Whether this target belongs to the call site and not to the ``Navigator``.
    static func belongsToPlace(_ target: ActionTarget) -> Bool {
        switch target {
        case .retry, .systemSettings: true
        case .setup, .accounts, .channelLists, .liveSettings, .portalSettings,
            .sync, .certificate, .downloadRules:
            false
        }
    }

    /// The view a target of the ``Navigator`` leads to — `nil` for the sync, which
    /// is not a view, and for the call site's own targets.
    ///
    /// **The downloads rules lead to the downloads**: the "Download on Wi-Fi only" switch
    /// sits there in the network sheet and has no view of its own.
    static func view(forItem target: ActionTarget) -> ViewID? {
        switch target {
        case .setup: .setup
        case .accounts: .accounts
        case .channelLists: .channelLists
        case .liveSettings: .liveSettings
        case .portalSettings: .portalSettings
        case .certificate: .certificates
        case .downloadRules: .downloads
        case .retry, .systemSettings, .sync: nil
        }
    }
}

/// The shell's path for the targets of the ``Navigator`` — see ``StateRoute``.
///
/// **`nil` is the normal case outside the shell** (probes, previews). Then
/// ``StateView`` draws no loud button for such a target: a button that leads nowhere is
/// worse than none.
struct StateRouteKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ActionTarget) -> Void)? = nil
}

extension EnvironmentValues {

    /// Siehe ``StateRouteKey``.
    var stateRoute: (@MainActor (ActionTarget) -> Void)? {
        get { self[StateRouteKey.self] }
        set { self[StateRouteKey.self] = newValue }
    }
}
